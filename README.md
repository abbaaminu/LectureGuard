# LectureGuard

LectureGuard is an offline-first Flutter app for biometric-assisted lecture
attendance. The mobile app is in `flutter_app/`; the optional React/Vite
prototype is isolated in `web_simulation/`.

## Requirements and setup

- Flutter 3.44.6 or newer with Android tooling installed.
- Xcode and CocoaPods for iOS builds (iOS builds require macOS).
- A Supabase project configured with the migrations below.

From the repository root, copy `flutter_app/env.example.json` to
`flutter_app/env.json` and fill in the project URL and the anon/publishable
client key. `env.json` is ignored by git. Never place a Supabase
`service_role` key in the app.

```powershell
cd flutter_app
flutter pub get
flutter run --dart-define-from-file=env.json
```

The app shows a setup error screen if either Supabase value is missing, or if
`SUPABASE_URL` is not an absolute `https://` URL (the anon key is sent as a
header on every request and must never travel over plain HTTP). For Android,
the project targets API level 23 or newer. For iOS, configure Face ID and
background fetch capabilities as appropriate for the deployment.

## Supabase migrations

Apply these SQL files in order using the Supabase CLI or SQL editor:

1. `supabase/migrations/001_lectureguard_schema.sql` — core tables, roles,
   policies, and reporting views.
2. `supabase/migrations/002_fix_rls_and_views.sql` — recursion-safe RLS
   helpers and invoker-secure views.
3. `supabase/migrations/003_school_settings_and_analytics.sql` — school-wide
   excused-attendance preference, weekly trends, and chronic-absence paging.
4. `supabase/migrations/004_harden_teacher_submission_logs.sql` — makes the
   teacher submission log staff-only; it is read through the
   `teacher_submission_logs()` function instead of the view.
5. `supabase/migrations/005_school_settings_left_join.sql` — keeps the
   reporting views and the chronic-absence page working when the single
   `school_settings` row is missing (excused absences then use the documented
   default of not counting as attended).

Configure admin and teacher roles through trusted administrative provisioning.
The client uses only the anon/publishable key; RLS enforces access.

## Attendance and biometric limitations

Check-ins are written to local SQLite before sync. The app caches the current
roster for offline use and syncs in batches when network reachability returns.
Completed session history remains available from local SQLite.

`local_auth` confirms that a fingerprint (or Face ID, where supported)
registered on this device was successfully used. It does **not** identify which
student supplied the biometric. Pass Mode therefore remains an assisted
attendance workflow; it is not proof of student identity.

On iPhone and iPad, Guided Access must be enabled and started by the device
operator, or a school MDM must apply supervised Single App Mode. Pass Mode
cannot enable Guided Access programmatically.

## Student identity options

Pass Mode records attendance against a student row, but the app has to be told
*which* student is standing at the tablet. The table lists the options that are
realistically available to a school; only teacher attestation is implemented
today.

| Option | How it would work | What it proves | Status in LectureGuard |
| --- | --- | --- | --- |
| Per-student QR / NFC card | The student presents their own card; the camera (QR) or NFC reader resolves the card token to a student id. | Possession of the card. | Not implemented. No scanner or NFC dependency is shipped. |
| Student-entered PIN bound to the student id | After the roster tap, the student types a short PIN that is bound to their student id (`students.id`). | Knowledge of a secret tied to one student. | Not implemented. The PIN in the app is the lecturer/admin exit and override PIN (`PinSecurityService`), never a student credential. |
| One device per student (BYOD) | Each student signs in on their own phone and checks themselves in; the session is scoped to their account. | Account possession. | Not implemented. Pass Mode is a shared invigilator tablet; only staff accounts sign in. |
| Teacher attestation | The invigilator taps the student on the roster and confirms the check-in. | The invigilator's judgement, recorded as `override_by` + `override_reason`. | **Implemented.** The tap is gated by the device biometric; when biometrics are unavailable the lecturer PIN authorises an override and the reason is stored on the record. |
| Per-student face enrolment | Each student's face is enrolled once, then matched at check-in. | Biometric identity of that student. | Not implemented. `local_auth` only verifies a fingerprint/Face ID enrolled on the shared device, which the limitation above explains is not student identity. |

**Implemented today: teacher attestation.** A roster tap plus device biometric (or
lecturer-PIN override with a stored reason) is an invigilator-attested check-in,
not a proof of student identity. The other four options need a new credential
store (card tokens, per-student PIN hashes, or face templates) and are out of
scope for the current schema.

## Pass Mode device lockdown

Pass Mode is not a kiosk out of the box. On Android the app calls
`startLockTask()`, and the operating system grants one of two levels:

| Level | How it is granted | Can the operator leave without the PIN? |
| --- | --- | --- |
| Screen pinning (`LOCK_TASK_MODE_PINNED`) | The default on a stock device with no device owner. | **Yes.** From Recents: **Unpin** (or Back + Recents) releases the task without asking for the app PIN. |
| Kiosk (`LOCK_TASK_MODE_LOCKED`) | A device-owner / MDM allow-lists the package with `setLockTaskPackages()`. | No. Only the device owner, or a reboot, leaves the task. |

Because Android screen pinning can be dismissed from Recents, Pass Mode on its
own is a deterrent, not an anti-cheat control. The app reports the level back to
Dart and the Pass Mode screen keeps a persistent warning banner visible for the
whole session whenever the lock did not engage; the banner is not a snackbar and
does not disappear after a few seconds.

### MDM / device-owner guide (real kiosk)

1. Enroll the attendance tablets as **fully managed devices** and make your MDM
   app the device owner. (A running app cannot promote itself to device owner;
   the device must be freshly provisioned or factory reset.)
2. From the device owner, allow-list the package for lock-task mode, e.g. in your
   DPC or MDM profile:

   ```java
   DevicePolicyManager dpm =
       (DevicePolicyManager) context.getSystemService(Context.DEVICE_POLICY_SERVICE);
   dpm.setLockTaskPackages(adminComponent, new String[] {
       "com.lectureguard.lecture_guard"
   });
   // Optional: lock down system UI while the task is running (API 28+).
   dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_NONE);
   ```

3. Keep LectureGuard installed for the work profile / managed device user and
   distribute it through the MDM. `startLockTask()` then enters
   `LOCK_TASK_MODE_LOCKED`, and the Pass Mode warning banner stays hidden.
4. Verify on a provisioned device with
   `adb shell dumpsys activity activities | findstr mLockTaskModeState`: it must
   report `LOCKED`. `PINNED` means step 2 did not apply.
5. Keep the exit PIN enabled: kiosk mode blocks Recents and Home, but ending a
   session still needs an authorised exit path.

### iOS

iOS has no equivalent API. Guided Access has to be started by the device
operator (triple-click the side or top button) or by an MDM applying supervised
Single App Mode. Pass Mode cannot enable it programmatically and shows no lock
warning on iOS.

## Development and validation

```powershell
cd flutter_app
flutter analyze
flutter test
```

The GitHub Actions workflow runs Flutter analysis and tests and executes the
PostgreSQL 16 RLS integration tests in `supabase/tests/rls_test.sql`.

## Release builds, signing and branding

```powershell
cd flutter_app
flutter build apk --release --dart-define-from-file=env.json
```

Release builds are minified by R8. `android/app/proguard-rules.pro` keeps Room's
generated database classes, WorkManager's workers and the Flutter workmanager
plugin by name because they are resolved reflectively at startup; removing those
rules reintroduces the "LectureGuard keeps stopping" crash on launch. WorkManager
is created on demand by `LectureGuardApplication` (the default
`androidx.startup` initialiser is removed in the manifest) so a failure there is
reported by the in-app startup guard instead of killing the process.

Signing is read from `flutter_app/android/key.properties`:

```properties
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=upload-keystore.jks
```

`storeFile` is resolved relative to `android/app`. Without that file the release
APK is signed with the debug key; Gradle prints a warning and the artifact must
not be published or installed as an update over a Play-signed build.

The launcher icon, adaptive/themed icons, splash mark and iOS app icons all come
from `branding/lectureguard_icon.svg`. Regenerate them after changing the
artwork (Pillow is the only requirement):

```powershell
cd flutter_app
python tool/generate_app_icons.py
```

## Optional web prototype

The React/Vite demonstration is separate from the Flutter app under
`web_simulation/`. Its packages and build are independent of mobile setup.
