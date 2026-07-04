package com.chabridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import org.json.JSONArray
import java.security.SecureRandom
import java.security.MessageDigest
import java.util.Base64
import java.util.Date
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class ChaBridgeSmsReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "ChaBridgeSync"
        private const val ACTION_SMS_RECEIVED = "android.provider.Telephony.SMS_RECEIVED"
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val PREF_DEFAULT_SYNC_KEY = "flutter.default_sync_inbox_key"
        private const val PREF_SELECTED_SYNC_KEY = "flutter.selected_sync_key_fallback"
        private const val PREF_LAST_SMS_SYNC_PREFIX = "flutter.last_sms_sync_ms_"
        private const val PREF_NATIVE_DEBUG_LOGS = "flutter.sms_sync_native_debug_logs_v1"
        private const val REMOTE_CIPHER_DOC_ID = "dataCipher"
        private const val NATIVE_SYNC_MARKER_SAFETY_MS = 60_000L
        private const val MAX_DEBUG_LOGS = 120
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_SMS_RECEIVED) {
            return
        }

        appendDebugLog(context, "SMS broadcast received.")
        uploadReceivedSmsNow(context, intent)
    }

    private fun uploadReceivedSmsNow(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        Executors.newSingleThreadExecutor().execute {
            try {
                FirebaseApp.initializeApp(context.applicationContext)
                val user = FirebaseAuth.getInstance().currentUser
                if (user == null) {
                    appendDebugLog(context, "Direct SMS upload skipped: no Firebase user.")
                    return@execute
                }

                val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent).toList()
                if (messages.isEmpty()) {
                    appendDebugLog(context, "Direct SMS upload skipped: no SMS messages in intent.")
                    return@execute
                }

                val db = FirebaseFirestore.getInstance()
                val syncKey = resolveSyncKey(context, user.uid, db)
                if (syncKey.isBlank()) {
                    appendDebugLog(context, "Direct SMS upload skipped: no selected/default inbox.")
                    return@execute
                }

                if (!hasInboxAccess(user.uid, syncKey, db)) {
                    appendDebugLog(context, "Direct SMS upload skipped: no inbox access for key=$syncKey.")
                    return@execute
                }

                val batch = db.batch()
                val keyBase64 = resolveCipherKeyBase64(user.uid, db)
                var count = 0
                var maxSyncedMs = 0L
                for (message in messages) {
                    val address = message.originatingAddress ?: message.displayOriginatingAddress ?: "Unknown"
                    val body = message.messageBody ?: message.displayMessageBody ?: ""
                    val smsDate = message.timestampMillis.takeIf { it > 0L }
                        ?: System.currentTimeMillis()
                    val docId = sha1("$address|$smsDate|$body")
                    val docRef = db.collection("sync_keys")
                        .document(syncKey)
                        .collection("sms")
                        .document(docId)

                    val payload = hashMapOf<String, Any?>(
                        "address" to encryptText(address, keyBase64),
                        "body" to encryptText(body, keyBase64),
                        "threadId" to null,
                        "smsDate" to Timestamp(Date(smsDate)),
                        "uploadedAt" to FieldValue.serverTimestamp(),
                        "source" to "android",
                    )
                    batch.set(docRef, payload, SetOptions.merge())
                    count++
                    if (smsDate > maxSyncedMs) {
                        maxSyncedMs = smsDate
                    }
                }

                Tasks.await(batch.commit())
                if (maxSyncedMs > 0L) {
                    val markerMs = maxOf(maxSyncedMs, System.currentTimeMillis()) +
                        NATIVE_SYNC_MARKER_SAFETY_MS
                    context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                        .edit()
                        .putLong("$PREF_LAST_SMS_SYNC_PREFIX$syncKey", markerMs)
                        .apply()
                }
                appendDebugLog(context, "Direct SMS upload complete: key=$syncKey count=$count.")
            } catch (e: Exception) {
                Log.e(TAG, "Direct SMS upload failed.", e)
                appendDebugLog(context, "Direct SMS upload failed: ${e.javaClass.simpleName}: ${e.message ?: ""}.")
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun resolveCipherKeyBase64(uid: String, db: FirebaseFirestore): String {
        val secretRef = db.collection("users")
            .document(uid)
            .collection("secrets")
            .document(REMOTE_CIPHER_DOC_ID)

        val secretDoc = Tasks.await(secretRef.get())
        val remoteKey = secretDoc.getString("keyBase64")?.trim().orEmpty()
        if (remoteKey.isNotEmpty()) {
            return remoteKey
        }

        val keyBytes = ByteArray(32)
        SecureRandom().nextBytes(keyBytes)
        val generatedKey = Base64.getEncoder().encodeToString(keyBytes)
        Tasks.await(
            secretRef.set(
                mapOf(
                    "keyBase64" to generatedKey,
                    "updatedAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            ),
        )
        return generatedKey
    }

    private fun encryptText(plainText: String, keyBase64: String): String {
        val keyBytes = Base64.getDecoder().decode(keyBase64)
        val ivBytes = ByteArray(16)
        SecureRandom().nextBytes(ivBytes)

        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(keyBytes, "AES"),
            IvParameterSpec(ivBytes),
        )
        val encryptedBytes = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return "${Base64.getEncoder().encodeToString(ivBytes)}:${Base64.getEncoder().encodeToString(encryptedBytes)}"
    }

    private fun resolveSyncKey(
        context: Context,
        uid: String,
        db: FirebaseFirestore,
    ): String {
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val selected = prefs.getString(PREF_SELECTED_SYNC_KEY, "")?.trim().orEmpty()
        if (selected.isNotEmpty()) return selected

        val defaultKey = prefs.getString(PREF_DEFAULT_SYNC_KEY, "")?.trim().orEmpty()
        if (defaultKey.isNotEmpty()) return defaultKey

        return try {
            val inboxes = Tasks.await(
                db.collection("users")
                    .document(uid)
                    .collection("inboxes")
                    .whereEqualTo("isDeleted", false)
                    .limit(1)
                    .get()
            )
            val first = inboxes.documents.firstOrNull() ?: return ""
            val key = (first.getString("syncKey") ?: first.id).trim()
            if (key.isNotEmpty()) {
                prefs.edit().putString(PREF_SELECTED_SYNC_KEY, key).apply()
            }
            key
        } catch (e: Exception) {
            appendDebugLog(context, "Direct SMS sync key lookup failed: ${e.message ?: ""}.")
            ""
        }
    }

    private fun hasInboxAccess(uid: String, syncKey: String, db: FirebaseFirestore): Boolean {
        return try {
            val inboxDoc = Tasks.await(
                db.collection("users")
                    .document(uid)
                    .collection("inboxes")
                    .document(syncKey)
                    .get()
            )
            inboxDoc.exists() && inboxDoc.getBoolean("isDeleted") != true
        } catch (e: Exception) {
            false
        }
    }

    private fun appendDebugLog(context: Context, message: String) {
        Log.d(TAG, message)
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val existing = prefs.getString(PREF_NATIVE_DEBUG_LOGS, null)
        val logs = if (existing.isNullOrBlank()) JSONArray() else JSONArray(existing)
        val line = "[${Date()}] $message"
        logs.put(line)
        while (logs.length() > MAX_DEBUG_LOGS) {
            logs.remove(0)
        }
        prefs.edit().putString(PREF_NATIVE_DEBUG_LOGS, logs.toString()).apply()
    }

    private fun sha1(value: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        return md.digest(value.toByteArray())
            .joinToString("") { b -> "%02x".format(b) }
    }
}
