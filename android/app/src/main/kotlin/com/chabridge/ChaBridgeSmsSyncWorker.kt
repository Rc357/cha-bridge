package com.chabridge

import android.content.Context
import android.provider.Telephony
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.security.MessageDigest
import java.util.Date

class ChaBridgeSmsSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    companion object {
        private const val TAG = "ChaBridgeSync"
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val PREF_DEFAULT_SYNC_KEY = "flutter.default_sync_inbox_key"
        private const val PREF_SELECTED_SYNC_KEY = "flutter.selected_sync_key_fallback"
        private const val PREF_LAST_SMS_SYNC_PREFIX = "native_last_sms_sync_ms_"
        private const val MAX_SMS_FETCH = 80
    }

    override suspend fun doWork(): Result {
        return try {
            FirebaseApp.initializeApp(applicationContext)
            val auth = FirebaseAuth.getInstance()
            val user = auth.currentUser
            if (user == null) {
                Log.d(TAG, "Native worker skipped: no authenticated user.")
                Result.retry()
            } else {
                val uid = user.uid
                val db = FirebaseFirestore.getInstance()
                val syncKey = resolveSyncKey(uid, db)
                if (syncKey.isBlank()) {
                    Log.d(TAG, "Native worker skipped: no target inbox key.")
                    Result.success()
                } else if (!hasInboxAccess(uid, syncKey, db)) {
                    Log.d(TAG, "Native worker skipped: no inbox access for key=$syncKey")
                    Result.retry()
                } else {
                    val uploaded = pushSms(syncKey, db)
                    Log.d(TAG, "Native worker sync done: key=$syncKey sms=$uploaded")
                    Result.success()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Native worker sync failed.", e)
            Result.retry()
        }
    }

    private fun resolveSyncKey(uid: String, db: FirebaseFirestore): String {
        val prefs = applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
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
            if (inboxes.documents.isEmpty()) {
                ""
            } else {
                val doc = inboxes.documents.first()
                val key = (doc.getString("syncKey") ?: doc.id).trim()
                if (key.isNotEmpty()) {
                    prefs.edit().putString(PREF_SELECTED_SYNC_KEY, key).apply()
                }
                key
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve sync key from Firestore.", e)
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
            Log.e(TAG, "Failed to verify inbox access for key=$syncKey", e)
            false
        }
    }

    private fun pushSms(syncKey: String, db: FirebaseFirestore): Int {
        val prefs = applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val lastSyncKey = PREF_LAST_SMS_SYNC_PREFIX + syncKey
        val lastSyncMs = prefs.getLong(lastSyncKey, 0L)

        val cursor = applicationContext.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.THREAD_ID,
            ),
            null,
            null,
            "${Telephony.Sms.DATE} DESC",
        ) ?: return 0

        cursor.use {
            var count = 0
            var maxSyncedMs = lastSyncMs
            val batch = db.batch()

            val addressIndex = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val threadIdIndex = it.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)

            while (it.moveToNext() && count < MAX_SMS_FETCH) {
                val smsDate = it.getLong(dateIndex)
                if (smsDate <= lastSyncMs) {
                    continue
                }

                val address = it.getString(addressIndex) ?: "Unknown"
                val body = it.getString(bodyIndex) ?: ""
                val threadId = if (threadIdIndex >= 0) it.getLong(threadIdIndex) else null

                val rawId = "$address|$smsDate|$body"
                val docId = sha1(rawId)

                val docRef = db.collection("sync_keys")
                    .document(syncKey)
                    .collection("sms")
                    .document(docId)

                val payload = hashMapOf<String, Any?>(
                    "address" to address,
                    "body" to body,
                    "threadId" to threadId,
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

            if (count == 0) {
                return 0
            }

            Tasks.await(batch.commit())
            prefs.edit().putLong(lastSyncKey, maxSyncedMs).apply()
            return count
        }
    }

    private fun sha1(value: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        return md.digest(value.toByteArray())
            .joinToString("") { b -> "%02x".format(b) }
    }
}
