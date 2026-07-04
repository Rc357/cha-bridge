# Cha Bridge

Cha Bridge is an Android-only Flutter app for people who use more than one
phone and still need access to SMS OTPs, messages, and call history when a
device is somewhere else.

Install Cha Bridge on the phone that receives SMS, sign in, choose a shared
inbox, and incoming SMS messages are uploaded to Firebase Firestore. Open the
same inbox from another signed-in device to see the messages through Firestore's
real-time stream.

## What The App Does

- Syncs incoming Android SMS messages automatically when they are received.
- Lets multiple signed-in devices open the same shared inbox.
- Shows synced SMS and call logs from Firebase in real time.
- Supports manual SMS and call-log sync when you want to backfill history.
- Supports multiple chat inboxes per account.
- Lets users set a default inbox for automatic background uploads.
- Supports password-protected inboxes.
- Supports biometric login and biometric unlock for protected inboxes.
- Supports light and dark themes.
- Uses Android product flavors for development, staging, and production builds.

The main use case is OTP relay: leave one Android phone at home, receive the OTP
there, and read it from another device logged into the same Cha Bridge account
and inbox.

## How SMS Sync Works

Cha Bridge has two SMS sync paths:

- **Incoming SMS auto-sync:** a native Android `BroadcastReceiver` receives
  `SMS_RECEIVED`, resolves the selected/default inbox, and uploads the received
  message directly to Firestore.
- **Manual/backfill sync:** the Flutter app reads the Android SMS inbox and
  uploads recent unsynced messages.

The native receiver also advances the local last-sync marker so reopening the
app does not re-upload the same SMS during resume sync.

## What Gets Synced

SMS documents are stored under:

```text
sync_keys/{syncKey}/sms/{smsId}
```

Call log documents are stored under:

```text
sync_keys/{syncKey}/calls/{callId}
```

Inbox metadata is stored under:

```text
users/{uid}/inboxes/{syncKey}
```

## Authentication

The app uses Firebase Authentication:

- Email/password sign-in and registration
- Google Sign-In
- Saved credential login with biometrics

The phone must be signed in at least once so automatic background SMS upload has
a Firebase user session and a selected/default inbox to target.

## Privacy And Security

Cha Bridge encrypts sensitive synced fields before upload:

- SMS sender address and body
- Call number, contact name, and call type

The Dart sync path uses `DataCipher`. The native Android incoming-SMS receiver
uses matching AES-CBC encryption and the same account cipher key. The key is
stored in Flutter Secure Storage on the Dart side and mirrored to:

```text
users/{uid}/secrets/dataCipher
```

This lets another signed-in device decrypt synced SMS/call data for the same
account.

## Android Only

Cha Bridge depends on Android SMS and call-log APIs:

- `READ_SMS`
- `RECEIVE_SMS`
- `READ_CALL_LOG`
- foreground/background sync permissions
- biometric authentication

iOS is not supported because Apple does not allow third-party apps to read the
system SMS inbox.

## Firebase Setup

1. Create a Firebase project.
2. Add an Android app.
3. Download `google-services.json`.
4. Place it at `android/app/google-services.json`.
5. Enable Firebase Authentication:
   - Email/Password
   - Google
6. Add the required Android SHA fingerprints for Google Sign-In.
7. Enable Cloud Firestore.
8. Deploy the included Firestore rules:

```bash
firebase deploy --only firestore:rules --project cha-bridge
```

## Run

Install dependencies:

```bash
flutter pub get
```

Run production on a real Android phone:

```bash
flutter run -t lib/main_production.dart --flavor=production
```

SMS and call-log permissions require a real Android device for end-to-end
testing.

## Build Flavors

The Android app has three flavors:

- `development` - `com.chabridge.dev`, app label `DEV Cha Bridge`
- `staging` - `com.chabridge.stg`, app label `STG Cha Bridge`
- `production` - `com.chabridge`, app label `Cha Bridge`

Run a flavor:

```bash
flutter run -t lib/main_development.dart --flavor=development
flutter run -t lib/main_staging.dart --flavor=staging
flutter run -t lib/main_production.dart --flavor=production
```

Build APKs:

```bash
flutter build apk -t lib/main_development.dart --flavor=development
flutter build apk -t lib/main_staging.dart --flavor=staging
flutter build apk -t lib/main_production.dart --flavor=production
```

If you use development or staging, add Firebase Android clients for
`com.chabridge.dev` and `com.chabridge.stg` and download an updated
`google-services.json`.

## Project Structure

```text
lib/
  app/
    modules/
      auth/
        bindings/
        controllers/
        views/
      sms_sync/
        bindings/
        controllers/
        services/
        views/
    services/security/
    widgets/
  main_development.dart
  main_staging.dart
  main_production.dart

android/app/src/main/kotlin/com/chabridge/
  ChaBridgeSmsReceiver.kt
  ChaBridgeSmsSyncWorker.kt
  MainActivity.kt
```

Key files:

- `ChaBridgeSmsReceiver.kt` - native Android incoming-SMS auto-upload.
- `sms_sync_service.dart` - Dart SMS/call-log backfill sync and encryption path.
- `sms_sync_controller.dart` - inbox selection, sync settings, and UI state.
- `data_cipher.dart` - AES encryption helper for Dart-side sync.
- `firestore.rules` - Firestore access rules.

## Current Limitations

- Automatic SMS upload requires a signed-in Firebase user on the receiving
  phone.
- The receiving phone must have SMS permission granted and a selected/default
  inbox.
- Android battery optimization and OEM background restrictions can affect
  background behavior on some devices.
