# LectureGuard Independent QA Report

Audit date: 2026-11-20

## Summary

| Status | Count |
|---|---:|
| PASS | 49 |
| FAIL | 0 |
| NOT VERIFIED | 11 |

## Phase 1 - Build health

| Item | Status | Evidence |
|---|---|---|
| android/ exists | PASS | Directory exists at [android/](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/android). |
| ios/ exists | PASS | Directory exists at [ios/](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/ios). |
| flutter pub get | PASS | `flutter pub get` completed with `Got dependencies!` and exit code 0. |
| flutter analyze | NOT VERIFIED | The command ran for more than 10 minutes with only `Analyzing flutter_app...`, then was stopped; it produced no errors/warnings and no completion result. |
| flutter test --coverage | PASS | Exit code 0; `36` tests passed, ending with `All tests passed!`. |
| flutter build apk --debug | PASS | Exit code 0; output ended with `√ Built build\app\outputs\flutter-apk\app-debug.apk`. |

### Command output: flutter pub get

```text
Resolving dependencies...
Got dependencies!
45 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
```

### Command output: flutter analyze

```text
Analyzing flutter_app...
```

The process was still running after 10 minutes and was stopped. No diagnostic completion was produced.

### Command output: flutter test --coverage

```text
00:02 +27: loading C:/.../test/sync_engine_test.dart
02:04 +33: loading C:/.../test/teacher_override_dialog_test.dart
02:09 +34: loading C:/.../test/pin_security_test.dart
02:10 +36: All tests passed!
```

Trimmed test count: **36 tests passed**.

### Command output: flutter build apk --debug

```text
Running Gradle task 'assembleDebug'...
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): share_plus, workmanager
Running Gradle task 'assembleDebug'... 257.8s
√ Built build\app\outputs\flutter-apk\app-debug.apk
```

### Coverage

`flutter test --coverage` generated `flutter_app/coverage/lcov.info`.

| Folder | Lines found | Lines hit | Coverage |
|---|---:|---:|---:|
| lib/models | 161 | 144 | 89.44% |
| lib/providers | 263 | 100 | 38.02% |
| lib/screens | 277 | 161 | 58.12% |
| lib/services | 642 | 504 | 78.50% |
| lib/widgets | 130 | 100 | 76.92% |
| Overall | 1473 | 1009 | 68.50% |

## Phase 2 - Database and RLS

**NOT VERIFIED.** The environment was checked for `docker` and `psql`; neither was present. Output:

```text
Name        Source
----        ----
flutter.bat C:\flutter\bin\flutter.bat
```

No Docker or psql executable was found, so migrations and `supabase/tests/rls_test.sql` could not be applied or executed. The script itself is present and contains assertions for all requested RLS behaviors:

- Anonymous isolation and view privilege checks: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:150)
- Student isolation, missing-record absence, and 40% chronic summary: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:188)
- Teacher isolation and prohibited inserts: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:223)
- Admin school-wide access and excused-setting update: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:279)
- Profile trigger: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:138)
- University grade outside 9-12: [rls_test.sql](/C:/Users/ABBA AMINU/LectureGuard/supabase/tests/rls_test.sql:71)

No database query result can honestly be reported in this environment.

### Database checklist

| Item | Status | Evidence |
|---|---|---|
| Apply migrations 001-003 to PostgreSQL 16 | NOT VERIFIED | Docker/psql unavailable; no psql output. |
| Teacher sees only assigned rows; no recursion | NOT VERIFIED | Only assertions exist in the SQL file; they were not executed. |
| Student sees only own rows and lectures | NOT VERIFIED | Only assertions exist in the SQL file; they were not executed. |
| Anon/student cannot read protected views | NOT VERIFIED | Only privilege/assertion SQL exists; no runtime result. |
| Admin sees everything | NOT VERIFIED | Only assertions exist in the SQL file; they were not executed. |
| Missing record counts absent; below 80% flagged | NOT VERIFIED | SQL assertions exist but were not executed. |
| Cross-teacher/cross-student insert denied | NOT VERIFIED | SQL assertions exist but were not executed. |
| auth.users trigger creates profile | NOT VERIFIED | SQL assertion exists but was not executed. |
| Grade level outside 9-12 accepted | NOT VERIFIED | Fixture inserts grade 13 and 8, but migrations were not executed. |

## Phase 2.5 - Requirement checklist

| Requirement | Status | Evidence |
|---|---|---|
| PopScope blocks Pass Mode back | PASS | Pass-mode guard uses `PopScope(canPop: false)` in [student_pass_mode_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/student_pass_mode_screen.dart:588) and [lecturer_pin_setup_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/lecturer_pin_setup_screen.dart:69). |
| Exit requires secure-storage PIN | PASS | Exit dialog verifies via `PinSecurityService` and secure storage in [pin_exit_dialog.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/widgets/pin_exit_dialog.dart:13). |
| No hard-coded/default PIN, fallback, or `2468` | PASS | Invalid/missing/unreadable web-prototype PIN state now resolves to an empty PIN in [offlineStore.ts](/C:/Users/ABBA AMINU/LectureGuard/src/services/offlineStore.ts:36); the exit dialog no longer displays a default PIN in [PinExitDialog.tsx](/C:/Users/ABBA AMINU/LectureGuard/src/components/PinExitDialog.tsx:102). Regression: `node qa/no_default_pin_regression.test.mjs`. |
| PIN uses PBKDF2, random salt | PASS | Random 16-byte salt and PBKDF2-HMAC-SHA256 at 100,000 iterations are implemented in [pin_security_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/pin_security_service.dart:29), [pin_security_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/pin_security_service.dart:106), and [pin_security_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/pin_security_service.dart:238). Test passed in `pin_security_test.dart`. |
| Lockout persists across restarts | PASS | Lockout timestamp, failure count, and lockout level are written to secure storage; the passed test names and verifies persistence in [pin_security_test.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/test/pin_security_test.dart:117). |
| First-run setup rejects weak PIN | PASS | Setup exists and rejects non-4-digit, `0000`, `1234`, and repeated digits in [pin_security_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/pin_security_service.dart:62); test output passed. |
| Android screen pinning wired | PASS | Method-channel implementation and `startLockTask()` are in [pass_mode_lock_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/pass_mode_lock_service.dart:9) and [MainActivity.kt](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/android/app/src/main/kotlin/com/lectureguard/lecture_guard/MainActivity.kt:19). |
| MainActivity extends FlutterFragmentActivity | PASS | [MainActivity.kt](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/android/app/src/main/kotlin/com/lectureguard/lecture_guard/MainActivity.kt:10). |
| Android USE_BIOMETRIC permission | PASS | [AndroidManifest.xml](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/android/app/src/main/AndroidManifest.xml:3). |
| iOS Face ID usage description | PASS | [Info.plist](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/ios/Runner/Info.plist:19). |
| Force-kill/relaunch restores Pass Mode | PASS | Test `restores active session, roster, lock, and records from SQLite` passed and restores `isLockedPassMode`; code is in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:300) and [session_lifecycle_test.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/test/session_lifecycle_test.dart:83). Physical kill/relaunch is NOT VERIFIED. |
| Virtualized ListView.builder | PASS | Fixed-item `ListView.builder` in [student_pass_mode_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/student_pass_mode_screen.dart:372). |
| A-Z jumps, empty letters, accented initials | PASS | Diacritic-insensitive sorting/indexing and skipping unavailable letters are implemented in [student_roster.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/student_roster.dart:1); tests passed. |
| Real-time search | PASS | Search text directly updates `visibleRoster` in [student_pass_mode_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/student_pass_mode_screen.dart:278). |
| 300-student widget test passes | PASS | Test output: `renders and searches a 300-student virtualized roster`; assertions at [student_pass_mode_test.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/test/student_pass_mode_test.dart:68). |
| local_auth biometricOnly true | PASS | [biometric_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/biometric_service.dart:69). |
| stickyAuth true | PASS | [biometric_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/biometric_service.dart:73). |
| Success writes local record | PASS | Check-in creates `AttendanceRecord` and calls `_db.upsertAttendanceRecord` in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:459). |
| Tile turns green/amber and locks | PASS | Present/late tile styling and `isLocked` disable are in [student_pass_mode_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/student_pass_mode_screen.dart:372). |
| Double-tap protection | PASS | `_busy` guard prevents repeated taps in [student_pass_mode_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/student_pass_mode_screen.dart:131). |
| Unavailable biometric path | PASS | Unavailable and locked biometric branches return PIN override path in [biometric_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/biometric_service.dart:46). |
| WAL enabled by PRAGMA | PASS | `PRAGMA journal_mode = WAL` is issued on database configuration in [local_database_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/local_database_service.dart:29). |
| PRAGMA journal_mode test returns wal | NOT VERIFIED | No test executes `PRAGMA journal_mode` and expects `wal`; only the setup call exists. |
| SQLite write before network call | PASS | Check-in calls `_db.upsertAttendanceRecord` before `scheduleDebouncedSync` in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:459). |
| Sync listener wifi/mobile/ethernet | PASS | The connectivity listener resolves wifi, ethernet, and mobile in [sync_engine_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/sync_engine_service.dart:85). |
| Sync on start/timer/after endSession | PASS | Start sync and timer are in [sync_engine_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/sync_engine_service.dart:102); endSession calls `syncNow()` in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:400). |
| Batch size exactly 50 | PASS | `batchChunkSize = 50` and loops use it in [sync_engine_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/sync_engine_service.dart:46), [sync_engine_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/sync_engine_service.dart:201). |
| Sessions upload before records | PASS | Session loop precedes record loop in [sync_engine_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/sync_engine_service.dart:201). |
| Partial failure/mid-sync edit/offline-online/poison-batch tests pass | PASS | 36-test output explicitly lists these sync tests as passed. |
| Deterministic session and record IDs | PASS | UUID v5 functions in [session_ids.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/session_ids.dart:10). |
| Session restore after restart | PASS | Active-session restore test passed; code in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:300). |
| endSession writes absent records | PASS | End transaction inserts absent records for roster members without a record in [local_database_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/local_database_service.dart:398). |
| Override reason and override_by | PASS | Reason-required UI in [teacher_override_dialog.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/widgets/teacher_override_dialog.dart:25); override_by set from the signed-in user in [lecture_guard_providers.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/providers/lecture_guard_providers.dart:507). |
| Class history works offline | PASS | Class history reads SQLite-backed data through `getHistory`; code and tests need no network? The screen loads `getClassHistory` in [class_history_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/class_history_screen.dart:35). Not manually browser/physical validated. |
| Admin trend charts | PASS | Weekly attendance chart code and `fl_chart` line chart exist in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:708). |
| Paginated chronic list >1000 | PASS | Page size 50 and offset range pagination are implemented in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:92); no 1000-row test was found. |
| Teacher submission log | PASS | Paginated view query in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:131). |
| CSV export button and formula escaping | PASS | Export button is wired in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:631); escaping and its passing test exist in [csv_export_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/csv_export_service.dart:3). |
| PDF export Unicode font | PASS | Roboto regular/bold fonts are loaded and used in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:258). |
| Visible error and retry state | PASS | Chronic/log/settings error panels with retry actions are in [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:435), [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:503), and [admin_analytics_screen.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/screens/admin_analytics_screen.dart:588). |
| Role routing blocks student/teacher admin | PASS | Auth gate routes only admin to admin screen in [auth_gate.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/widgets/auth_gate.dart:92). |
| No service_role or JWT-like secret | PASS | Grep found no `service_role` or JWT-like string in app source. |
| env.json gitignored | PASS | [`.gitignore`](/C:/Users/ABBA AMINU/LectureGuard/.gitignore:14) and [`.gitignore`](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/.gitignore:31) ignore env.json. |
| Clear missing-config error | PASS | Missing URL/key produces a setup screen in [main.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/main.dart:10). |
| CI workflow and commands | PASS | Workflow exists and mirrors `flutter pub get`, `flutter analyze`, `flutter test`, and RLS psql in [flutter-ci.yml](/C:/Users/ABBA AMINU/LectureGuard/.github/workflows/flutter-ci.yml:1). |

## Phase 3 - Known limitations

PASS: [README.md](/C:/Users/ABBA AMINU/LectureGuard/README.md:48) states that `local_auth` does not identify which student supplied the biometric and recommends the assisted workflow, while noting real-identity options are not provided by the API itself. It also documents iPhone/iPad Guided Access/MDM limitations.

## Prioritized defect list

### Resolved High

- **QA-HIGH-001 — Default lecturer PIN `2468` in the web prototype.** Resolved by removing the fallback and UI disclosure; absent/invalid PIN now remains unconfigured. Regression: `node qa/no_default_pin_regression.test.mjs`.

### Medium

- **WAL behavior has no runtime assertion test.** The PRAGMA is present, but no test reads `PRAGMA journal_mode` and verifies `wal`.
  - Evidence: [local_database_service.dart](/C:/Users/ABBA AMINU/LectureGuard/flutter_app/lib/services/local_database_service.dart:34).

### Low

- No additional confirmed source defects were found by static and automated checks.

## Final verdict

NOT READY

Reason: Database RLS verification remains NOT VERIFIED because PostgreSQL/Docker/psql are unavailable; `flutter analyze` also did not complete during the original audit. QA-HIGH-001 has been fixed; the READY gate is still not met.

## What still needs manual testing

1. Physical Android airplane-mode check-in, reconnect, and verify sync.
2. Physical iPhone airplane-mode check-in, reconnect, and verify sync.
3. Android fingerprint prompt and cancel/unavailable paths.
4. iPhone Face ID prompt and cancel/unavailable paths.
5. Android Home button and app switcher behavior during Pass Mode.
6. iPhone Home button/app switcher behavior during Pass Mode.
7. Force-kill and relaunch on Android, confirm active locked Pass Mode restores.
8. Force-kill and relaunch on iPhone, confirm active locked Pass Mode restores.
9. Wrong-PIN attempts until lockout, relaunch while locked, and lockout expiry.
10. Scroll/smoothness of the 300-student roster on a physical Android phone.
11. Scroll/smoothness of the 300-student roster on a physical iPhone.
12. Open exported CSV on Android and verify formula escaping and readable fields.
13. Open exported CSV on iPhone and verify formula escaping and readable fields.
14. Open exported PDF on Android and verify embedded Unicode/Roboto text.
15. Open exported PDF on iPhone and verify embedded Unicode/Roboto text.
