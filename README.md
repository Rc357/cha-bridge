# Cha Bridge

Cha Bridge is an Android-only Flutter app for syncing a phone's SMS inbox and
call history into Firebase Firestore. It is built around authenticated "Chat
Inboxes": each inbox has a Firebase sync key, and the phone uploads SMS and call
records into that sync key so they can be viewed again after sign-in.

The project follows the local mobile-boilerplate flavor layout with separate
development, staging, and production Dart entrypoints.

## What it does

- Authenticates users with Firebase Email/Password or Google Sign-In.
- Supports saved email/password login with device biometrics.
- Lets a signed-in user create, select, protect, and delete Chat Inboxes.
- Reads Android SMS inbox messages with runtime permission.
- Reads Android call logs with runtime permission.
- Uploads SMS records to `sync_keys/{syncKey}/sms/{smsId}`.
- Uploads call records to `sync_keys/{syncKey}/calls/{callId}`.
- Stores user inbox metadata under `users/{uid}/inboxes/{syncKey}`.
- Supports manual sync, sync on app resume, in-app periodic sync, WorkManager
  background sync, incoming-SMS-triggered sync, and a foreground relay service.
- Stores app settings such as selected/default inbox and sync intervals in local
  preferences.

## Security model

The Dart sync path initializes `DataCipher` and encrypts sensitive text fields
before upload:

- SMS `address` and `body`
- Call `number`, `name`, and `callType`

The encryption key is stored locally in Flutter Secure Storage and mirrored to
`users/{uid}/secrets/dataCipher` so the same account can decrypt synced data
across app sessions/devices.

Inbox passwords are stored as SHA-256 hashes in the user's inbox document.
Biometric unlock is available for protected inboxes when enabled in the app.

Current caveat: the native Android `ChaBridgeSmsSyncWorker` path writes SMS
fields directly from Kotlin and does not use the Dart `DataCipher`. Prefer the
Dart sync/relay paths for encrypted uploads unless the native worker is updated
to use the same encryption scheme.

## Firebase data layout

```text
users/{uid}/inboxes/{syncKey}
  name
  syncKey
  isPasswordProtected?
  passwordHash?
  isDeleted
  deletedAt
  createdAt

users/{uid}/secrets/dataCipher
  keyBase64
  updatedAt

sync_keys/{syncKey}
  ownerUid
  name
  isDeleted
  deletedAt
  createdAt

sync_keys/{syncKey}/sms/{smsId}
  address
  body
  threadId
  smsDate
  uploadedAt
  source

sync_keys/{syncKey}/calls/{callId}
  number
  name
  callType
  durationSec
  callDate
  uploadedAt
  source
```

Firestore rules are defined in `firestore.rules`.

## Platform support

Android is the supported production target. The app requests these capabilities
through `android/app/src/main/AndroidManifest.xml`:

- Internet access
- SMS read/receive access
- Call log read access
- Biometric authentication
- Notifications and foreground data-sync service support
- Wake lock, boot completed, and battery optimization exemption support

The app requires runtime permission grants from the user before reading SMS or
call logs.

No iOS platform files are kept in this repository. Apple does not allow
third-party apps to read the system SMS inbox, and this app's core sync features
depend on Android SMS and call-log APIs.

## Firebase setup

1. Create a Firebase project.
2. Add an Android app.
3. Download `google-services.json`.
4. Place it at `android/app/google-services.json`.
5. Enable Firebase Authentication providers:
   - Email/Password
   - Google
6. Configure Google Sign-In for Android, including the required SHA certificate
   fingerprints in Firebase.
7. Enable Cloud Firestore.
8. Deploy the included Firestore rules:

```bash
firebase deploy --only firestore:rules --project cha-bridge
```

## Run locally

Install dependencies:

```bash
flutter pub get
```

Run on an Android device:

```bash
flutter run -t lib/main_production.dart --flavor=production
```

Android SMS and call log permissions are device-only features, so use a real
Android phone for end-to-end testing.

## Flavors

The Android app has three Gradle product flavors:

- `development` - package suffix `.dev`, app label `DEV Cha Bridge`
- `staging` - package suffix `.stg`, app label `STG Cha Bridge`
- `production` - package `com.chabridge`, app label `Cha Bridge`

Use the matching Dart entrypoint for each flavor:

```bash
flutter run -t lib/main_development.dart --flavor=development
flutter run -t lib/main_staging.dart --flavor=staging
flutter run -t lib/main_production.dart --flavor=production
```

Build APKs with:

```bash
flutter build apk -t lib/main_development.dart --flavor=development
flutter build apk -t lib/main_staging.dart --flavor=staging
flutter build apk -t lib/main_production.dart --flavor=production
```

If you keep the `.dev` and `.stg` package suffixes, Firebase must include
Android app clients for `com.chabridge.dev` and `com.chabridge.stg` in
`android/app/google-services.json`.

## Background sync modes

Cha Bridge has several sync paths:

- Manual sync from the app UI.
- App-resume sync when enabled.
- In-app periodic sync while the app process is alive.
- WorkManager periodic background sync with network connectivity constraints.
- Incoming SMS trigger through Android receivers and the Telephony listener.
- Foreground relay service using `flutter_foreground_task`, with a persistent
  notification and battery optimization handling.

Background sync depends on Android version, notification permission, battery
optimization settings, and whether Firebase authentication can be restored from
saved credentials.

## Important source files

- `lib/main.dart` - default production app entrypoint.
- `lib/main_development.dart`, `lib/main_staging.dart`,
  `lib/main_production.dart` - flavor-specific entrypoints.
- `lib/app/app_runner.dart` - shared bootstrap for orientation, WorkManager, and
  foreground-task setup.
- `lib/app/app_flavor.dart` - flavor metadata used by Dart entrypoints.
- `lib/app/chat_sync_app.dart` - Material app, theme, and bootstrap screen.
- `lib/app/app_bootstrap_screen.dart` - Firebase initialization gate.
- `lib/app/modules/auth/bindings/` - GetX dependency binding for auth.
- `lib/app/modules/auth/controllers/` - auth controller.
- `lib/app/modules/auth/views/` - auth gate and login/register UI.
- `lib/app/modules/sms_sync/bindings/` - GetX dependency binding for SMS sync.
- `lib/app/modules/sms_sync/controllers/` - inbox management, sync settings,
  background/relay toggles, protected inbox logic.
- `lib/app/modules/sms_sync/views/` - main inbox and sync UI.
- `lib/app/modules/sms_sync/services/` - SMS/call permission checks, local
  reads, encryption, Firestore writes, WorkManager background dispatcher,
  incoming SMS trigger, and foreground relay sync.
- `lib/app/services/security/data_cipher.dart` - AES encryption key management
  and encrypt/decrypt helpers.
- `lib/app/widgets/` - shared app widgets such as the Cha Bridge logo.
- `android/app/build.gradle.kts` - Android flavor and dependency setup.
- `android/app/src/main/kotlin/com/chabridge/` - native Android SMS receiver
  and worker integration.

## Notes for maintainers

- The package name in `pubspec.yaml` is `sms_sync_app`, while the user-facing
  app name is Cha Bridge.
- The app stores saved login credentials in Flutter Secure Storage to support
  biometric login and background auth restore.
- Firestore rules allow a signed-in owner, or a user with an inbox document for
  that sync key, to access the related sync data.
- Deleted inboxes are soft-deleted with `isDeleted` and `deletedAt`.
- SMS and call document IDs are SHA-1 hashes of stable record fields to reduce
  duplicate uploads.
