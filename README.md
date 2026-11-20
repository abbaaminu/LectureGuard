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

The app shows a setup error screen if either Supabase value is missing. For
Android, the project targets API level 23 or newer. For iOS, configure
Face ID and background fetch capabilities as appropriate for the deployment.

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

## Development and validation

```powershell
cd flutter_app
flutter analyze
flutter test
```

The GitHub Actions workflow runs Flutter analysis and tests and executes the
PostgreSQL 16 RLS integration tests in `supabase/tests/rls_test.sql`.

## Optional web prototype

The React/Vite demonstration is separate from the Flutter app under
`web_simulation/`. Its packages and build are independent of mobile setup.
