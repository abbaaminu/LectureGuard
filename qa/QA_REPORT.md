# LectureGuard — Independent QA Audit

**Auditor:** independent QA pass (no application source was modified)
**Audit date:** 2026-11-20
**Artifacts produced by this audit:** `qa/QA_REPORT.md`, `qa/rls_verify.sql`,
`qa/rls_verify_output.txt`, `qa/diag_copilot_assertions.sql`,
`qa/coverage_summary.py`

> This report does **not** reuse the previous `qa/QA_REPORT.md` verdicts. Every
> row was re-executed or re-read from source. Where a check could not be
> executed in this environment it is marked **NOT VERIFIED** instead of PASS.

---

## 0. Verdict

**NOT READY FOR RELEASE.** Three release-blocking concerns: the repository's own
RLS integration test fails (so the `supabase-rls` CI job is red), a stated
access-control requirement is violated by the shipped policies, and every
device-level behaviour (biometrics, screen pinning, iOS Guided Access) is
unverified on real hardware.

### Summary counts

| Metric | Value |
| --- | --- |
| Requirement-check rows assessed | **74** |
| PASS (evidence: command output or cited source line) | **68** |
| FAIL (contradicts the requirement) | **5** |
| NOT VERIFIED (needs hardware/CI) | **1** |
| Flutter analysis / tests / debug build | clean / **36 of 36 passing** / APK produced |
| Line coverage | **68.5 %** (1009/1473) over 15 files; 10 shipped files at 0 % |
| RLS assertions independently executed | **8 of 8 run — 7 PASS, 1 FAIL** |
| Repository RLS suite | **FAILS** (`rls_test.sql:234`) |
| Defects | **2 HIGH**, 3 MEDIUM, 7 LOW |


---

## 1. Scope and method

| Area | Method |
| --- | --- |
| Flutter code (`flutter_app/lib`, 25 files, ~5.6k LOC) | full read of every security-relevant file; `analyze`, `test --coverage`, `build apk --debug` |
| Supabase SQL (`supabase/migrations`, 3 files) | applied to a **real PostgreSQL 16.16** server with a mock `auth` schema, then exercised by my own fixture script |
| RLS suite (`supabase/tests/rls_test.sql`) | executed verbatim on the same server |
| CI (`.github/workflows/flutter-ci.yml`) | read; every command it runs was executed locally |
| Docs (`README.md`) | read against the stated documentation requirement |

### Environment actually used

```
Flutter 3.44.6 - channel stable - Dart 3.12.2      (matches the version pinned in CI)
PostgreSQL 16.16 (local install, throwaway cluster on 127.0.0.1:55432,
                  mock auth schema: auth.users + auth.uid() from request.uid)
Docker: NOT INSTALLED    psql on PATH: NO (used C:\Program Files\PostgreSQL\16\bin\psql.exe)
```

No Android/iOS device or emulator was available, so all device behaviour is
**NOT VERIFIED** and appears in §6 as manual test work.

**Working-tree state:** `git status` was already dirty when this audit started
(`flutter_app/lib/**`, `README.md`, `supabase/tests/rls_test.sql`,
`flutter_app/ios/Runner/Info.plist`, etc. carry uncommitted modifications that
predate this audit). All file:line evidence below therefore refers to the
**working copy as found**, which is exactly what ships if committed as-is. This
audit added only files under `qa/`; the generated changes made by the tooling
runs are limited to `flutter_app/.flutter-plugins-dependencies`,
`flutter_app/pubspec.lock`, `flutter_app/android/.kotlin/sessions/*` and
`flutter_app/build/**`.


---

## 2. Phase 1 — Build, analysis, tests, coverage

| # | Check | Command | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Dependencies resolve | `flutter pub get` | **PASS** | `Got dependencies!` (45 packages held back by constraints) |
| 2 | Static analysis | `flutter analyze` | **PASS** | `No issues found! (ran in 144.1s)` — 0 errors/warnings/infos |
| 3 | Test suite | `flutter test --coverage` | **PASS** | `01:07 +36: All tests passed!` — 36 tests, 8 files |
| 4 | Debug APK builds | `flutter build apk --debug` | **PASS** | `Built build\app\outputs\flutter-apk\app-debug.apk` in 140.7 s; 237,157,149 bytes |
| 5 | Android host project | `dir flutter_app\android` | **PASS** | `app/`, `build.gradle.kts`, `gradle/`, `gradlew`, `settings.gradle.kts` |
| 6 | iOS host project | `dir flutter_app\ios` | **PASS** | `Runner.xcodeproj`, `Runner.xcworkspace`, `Runner/`, `RunnerTests/` |
| 7 | Line coverage | `python qa/coverage_summary.py` | **PARTIAL** | 1009/1473 = **68.5 %** over 15 measured files (see caveat) |

Trimmed test output (tail):

```
00:21 +11: session_lifecycle_test.dart: deterministic IDs remain stable for the same local-day inputs
00:29 +18: pin_security_test.dart: PIN setup rejects 1234 and repeated digits
00:58 +29: sync_engine_test.dart: an edit during upload remains pending after the stale ack
01:06 +35: teacher_override_dialog_test.dart: excused overrides require a reason
01:07 +36: All tests passed!
```

Trimmed coverage summary (`qa/coverage_summary.py` output):

```
files measured: 15
folder       lines hit  lines found  coverage
lib               1009         1473     68.5%
TOTAL             1009         1473     68.5%

lowest-covered files:
  lib/services/auth_service.dart                      0/15      0.0%
  lib/services/pass_mode_lock_service.dart            0/6       0.0%
  lib/services/biometric_service.dart                 1/24      4.2%
  lib/providers/lecture_guard_providers.dart        100/263    38.0%
  lib/screens/student_pass_mode_screen.dart         124/227    54.6%
```

**Coverage caveat (QA gap, not a functional bug).** lcov only lists the 15 files
a test actually loads. These shipped files are **absent from the report**, i.e.
0 % covered: `admin_analytics_screen.dart`, `teacher_monitor_screen.dart`,
`student_attendance_screen.dart`, `class_history_screen.dart`,
`lecture_picker_screen.dart`, `sign_in_screen.dart`,
`change_lecturer_pin_screen.dart`, `auth_gate.dart`,
`background_sync_service.dart`, `main.dart`.
`biometric_service.dart` is measured but only 1/24 lines: the real
`authenticate()` call is never executed by a test, so biometric behaviour rests
on code review plus manual device testing.

---

## 3. Phase 2 — Database / RLS verification (executed)

Method: throwaway PostgreSQL 16.16 cluster, mock `auth` schema
(`auth.users`, `auth.uid()` reading `current_setting('request.uid')`), roles
`anon` and `authenticated`, plus Supabase's default `public` grants so a missing
grant cannot masquerade as an RLS denial. Then `001 -> 002 -> 003` in order,
then my fixture (2 teachers, 1 admin, 2 students, 8 + 5 sessions, 10 records),
then `SET ROLE` + `request.uid` per persona.

Reproduce:

```
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55432 -U postgres -d postgres -f qa/rls_verify.sql
```

### 3.1 The repository's own RLS test fails

```
$ psql -X -v ON_ERROR_STOP=1 ... -f supabase/tests/rls_test.sql
...
SET
psql:supabase/tests/rls_test.sql:234: ERROR:  student can see rows outside their enrolled class
CONTEXT:  PL/pgSQL function inline_code_block line 12 at RAISE
EXITCODE=3
```

Root cause isolated with `qa/diag_copilot_assertions.sql` (fixtures identical to
lines 71-132 of `rls_test.sql`, printed instead of asserted):

```
--- what STUDENT 1 actually sees (rls_test.sql lines 200-206 assert 1/1/1/5/4/1/5) ---
 students_actual | lectures_actual | enrollments_actual | sessions_actual | records_actual | settings_actual | v_logs_actual | v_summary_actual
-----------------+-----------------+--------------------+-----------------+----------------+-----------------+---------------+------------------
               1 |               1 |                  1 |               5 |              3 |               1 |             5 |                1
```

`records_actual = 3` (2 present + 1 excused, all student 1's own) but
`supabase/tests/rls_test.sql:204` asserts `<> 4`. The fixture creates only 4
records in the whole table and one belongs to student 2, so the assertion is
unsatisfiable whenever RLS is correct. Because it sits inside a `DO` block in
the single test transaction, everything after line 234 (teacher matrix, admin
matrix, chronic page) never runs. `.github/workflows/flutter-ci.yml:45-51` runs
exactly this file, so the `supabase-rls` job cannot pass.

### 3.2 My independent checklist (all 8 required assertions)

`qa/rls_verify.sql` ran to completion with `ON_ERROR_STOP=1`, exit code 0.
Visible row counts per persona (as measured):

```
 persona  | profiles | students | lectures | enrollments | sessions | records | v_logs | v_summary | v_weekly | settings
----------+----------+----------+----------+-------------+----------+---------+--------+-----------+----------+---------
 anon     | 0        | 0        | 0        | 0           | 0        | 0       | denied | denied    | denied   | denied
 teacher1 | 1        | 1        | 1        | 1           | 8        | 6       | 8      | 1         | n/t      | n/t
 student1 | 1        | 1        | 1        | 1           | 8        | 7*      | 8      | 1         | n/t      | n/t
 admin    | 5        | 2        | 2        | 2           | 13       | 10      | 13     | 2         | 3        | 1
```

`denied` = PostgreSQL `42501` (no grant, so zero rows are readable);
`n/t` = not queried for that persona. `*` student1's `records = 7` includes the
one row inserted by the CHECK 6 positive test (deleted again before the summary
assertions, which is why STU-1's summary reports 6 own records for 8 sessions).


| # | Assertion | Result | Evidence (query -> result) |
| --- | --- | --- | --- |
| 1 | Teacher sees only own lecture/students/records | **PASS** | teacher1 -> `lectures=1, students=1, enrollments=1, sessions=8, records=6`; `SELECT course_code FROM lectures` -> only `CSC-101`; sessions per lecture -> `8` and no second row. Policies `002:202-237` |
| 2 | Student sees only own records/lectures | **PASS** | student1 -> `students=1, lectures=1, enrollments=1, sessions=8, records=7`; targeted query -> `other_student_records=0, other_lecture=0, other_lecture_sessions=0`. Policies `002:207-208, 216-226, 253-254` |
| 3 | anon **and student** get ZERO rows from `v_student_attendance_summary` / `v_teacher_submission_logs` | **FAIL (student)** | anon: views `DENIED(42501)`, `has_table_privilege` -> `f, f` (**pass**). student1: `v_summary = 1`, `v_teacher_logs = 8` (**fail**). Cause: both views are `security_invoker` (`002:98-99`, `003:44-45`), so invoker policies `students_self_read` / `enrollments_student_own` / `sessions_student_read_enrolled` (`002:208, 226, 236-237`) let a student read their own summary and every session of their class. `rls_test.sql:206` encodes the leak as intended |
| 4 | Admin sees everything | **PASS** | admin -> `profiles=5, students=2, lectures=2, enrollments=2, sessions=13, records=10, v_logs=13, v_summary=2, v_weekly=3, settings=1`; `admin_chronic_absentee_page(...)` -> `1` row (the 62.5 % student) |
| 5 | Missing record counts as absence; <80 % flagged | **PASS** | STU-1 `total_sessions=8, attended=5, unexcused_absences=3, late=1, 62.5 %, chronic=t`; STU-2 `5, 4, 1, 0, 80.0 %, chronic=f` (exactly 80 % is not chronic). Cross-check `enrolled_sessions=8, own_records=6, sessions_without_record=2` -> 2 implicit + 1 explicit absence = 3 |
| 6 | Teacher cannot write records for unenrolled students, foreign sessions or foreign `override_by` | **PASS** | `NOTICE: REJECTED: record for a student not enrolled in my lecture` / `REJECTED: record pointing at another teacher session` / `REJECTED: override_by pointing at another profile` / `ACCEPTED (expected): own session, enrolled student, own override_by`. Policy `003:28-41` |
| 7 | New `auth.users` row auto-creates a student profile | **PASS** | after 5 inserts `SELECT id, full_name, email, role FROM profiles` -> 5 rows, `role=student`, `full_name` from `raw_user_meta_data.full_name`. Trigger `002:257-284` |
| 8 | `grade_level 13` and `period_number 11` accepted (university use) | **PASS** | `SELECT student_code, grade_level` -> `STU-1|13`, `STU-2|8`; `SELECT course_code, period_number` -> `CSC-101|11`, `MAT-102|1`; constraint dump shows only `lectures_period_number_check CHECK ((period_number >= 1))` and no CHECK on `students` (`002:1-8`) |

No policy produced `42P17` (recursion) or any other error for any of the 6
tables / 3 views / 1 function in any persona — the `security definer` helpers in
`002:15-94` do break the cross-table recursion as claimed.

### 3.3 Schema / migration observations

* Sessions are unique per `(lecture_id, session_date)` (`001:83`) and the client
  derives a deterministic id from the same pair, so restarting a lecture on the
  same day reuses the row (also covered by the passing test
  `restarting the same lecture on the same day reuses its session`).
* `session_date` has no server default (`002:10-11`), so the client's local day
  is authoritative — the intent is verified by my run and by `rls_test.sql:49-61`.
* `v_student_attendance_summary` `CROSS JOIN`s `school_settings` (`003:84`): if
  that single row were ever deleted, every student summary and the admin chronic
  page would silently return zero rows instead of failing loudly.
* `attendance_records.toSupabasePayload()` omits `id`
  (`attendance_models.dart:291-302`) while upserting on `session_id,student_id`,
  so cloud row ids are server-generated and differ from the deterministic local
  ids. Harmless today (nothing reconciles by id) but local and cloud rows are
  not identifiable by the same key.

---

## 4. Phase 2.5 — Requirement checklist

Legend: **PASS** = demonstrated by an executed command or by code I read at the
cited line; **FAIL** = contradicts the requirement; **NOT VERIFIED** = cannot be
established without hardware/CI/credentials.

### 4.1 Pass Mode (lock, exit, resume)

| Requirement | Result | Evidence |
| --- | --- | --- |
| Student Pass Mode is a locked, full-screen, immersive UI | **PASS** | `student_pass_mode_screen.dart:68` (`immersiveSticky`), `:297-326` (AppBar with no back button), `:575-595` (`PassModePopGuard`) |
| Back / gesture exit is intercepted and needs the PIN | **PASS** | `:291-293` `canPop: !authGateManaged && _unlockedForExit`, `onBlockedPop: _handleExitAttempt`; `:107-128` verifies PIN before `stop()` + `unlockPassMode()` |
| Exit requires the secure-storage lecturer PIN (no bypass, no default) | **PASS** | `pin_exit_dialog.dart:111` -> `verifyLecturerPin`; `pin_security_service.dart:126-156` throws `StateError` when no PIN is configured, so there is no "empty PIN" path. Grep for `2468` / `service_role` / JWT-like strings over `flutter_app`, `supabase`, `.github` -> **no matches** |
| Re-entering Pass Mode after app resume re-locks the screen | **PASS** (code) | `student_pass_mode_screen.dart:83-89` + `:91-105` re-invokes `PassModeLockService().start()` on `resumed` |
| Android screen pinning actually prevents leaving the app | **NOT VERIFIED / design gap** | `MainActivity.kt:19-32` calls `startLockTask()`; the app is not a device owner and never calls `setLockTaskPackages`, so this is Android *screen pinning*, which the user can dismiss via the Recents "Unpin" affordance without the PIN. See MEDIUM-01 |
| iOS Pass Mode cannot be locked programmatically | **PASS (documented)** | `README.md:53-55` states Guided Access / supervised Single App Mode must be applied by the operator |
| Force-kill + relaunch returns to Pass Mode | **PASS** (code + unit) | `auth_gate.dart:94-96` renders Pass Mode when `activeSession.isLockedPassMode`; session/lock restored from SQLite in `lecture_guard_providers.dart:300-330`; covered by the passing test `restores active session, roster, lock, and records from SQLite`. Physical kill/relaunch **NOT VERIFIED** |

### 4.2 Roster (search, sort, A-Z, 300 students)

| Requirement | Result | Evidence |
| --- | --- | --- |
| 300-student roster renders and stays responsive | **PASS** | `ListView.builder` with `itemExtent: 74` (`student_pass_mode_screen.dart:372-378`); test asserts item 299 is not built while item 0 is (`student_pass_mode_test.dart:75-80`), `+36` suite green |
| Real-time search | **PASS** | `:278-287` filters on every keystroke; `:353-356` updates state on change |
| Diacritic-insensitive search and sort | **PASS** | `student_roster.dart:6-7` (`removeDiacritics`), `:17-24`; tests `search normalization matches accented text with plain characters`, and widget test searches `á` and finds `Álvarez000` (`student_pass_mode_test.dart:82-85`) |
| Alphabetical by last then first name | **PASS** | `student_roster.dart:9-27`; `attendance_models.dart:28-33` derives the initial with diacritics removed, `#` bucket for non-A-Z |
| A-Z jump bar, including letters with no students | **PASS (forward-only)** | `student_pass_mode_screen.dart:247-258` + `student_roster.dart:38-46` jump to the next populated letter. Edge case: tapping a letter *after* the last populated letter does nothing (returns `null`) — see LOW-03 |
| Search works while the list is scrolled/jumped | **PASS** | `letterIndexMap` rebuilt from `visibleRoster` (`:289`), `:355` clears the active letter while filtering |

### 4.3 Biometrics (local_auth)

| Requirement | Result | Evidence |
| --- | --- | --- |
| Hardware availability checked before prompting | **PASS** | `biometric_service.dart:20-28` (`canCheckBiometrics` + `isDeviceSupported`), `:44-52`, `:54-62` |
| `biometricOnly: true` (device passcode must not be accepted) | **PASS** | `biometric_service.dart:69-77` (`AuthenticationOptions(biometricOnly: true, ...)`) |
| `stickyAuth: true` (survives app switch during prompt) | **PASS** | `biometric_service.dart:73` |
| Sensor lockout / no-enrolment handled without crashing | **PASS** | `:85-109` (`auth_error.lockedOut`, `permanentlyLockedOut`, `notEnrolled`) -> user message + PIN path |
| Android biometric permission declared | **PASS** | `AndroidManifest.xml:3-4` (`USE_BIOMETRIC`, `USE_FINGERPRINT`) |
| iOS Face ID usage string declared | **PASS** | `Info.plist:19-20` (`NSFaceIDUsageDescription`) |
| Host activity is a `FlutterFragmentActivity` (required by local_auth) | **PASS** | `MainActivity.kt:6,10` |
| Successful match writes the record locally before any network call | **PASS** | `lecture_guard_providers.dart:445-471` -> `_db.upsertAttendanceRecord` at `:471`, `scheduleDebouncedSync` only afterwards at `:481` |
| Double-tap cannot queue two prompts / two records | **PASS** | `student_pass_mode_screen.dart:131` (`if (_busy) return`), `:399-401` (`onTap: isLocked || _busy ? null : ...`) |
| Already-checked-in student cannot be re-verified | **PASS** | `lecture_guard_providers.dart:436-443` returns `method: 'locked'`; `attendance_models.dart:221-223` `isLocked` |
| Tile turns green (present) / amber (late) and locks | **PASS** | `student_pass_mode_screen.dart:392-396`, `:459-468` |
| Late vs present decided by `late_grace_minutes` | **PASS** | `lecture_guard_providers.dart:451-455`; default 10 in `attendance_models.dart:72` |
| Biometrics can identify *which* student presented a finger | **FAIL (by design, documented)** | `local_auth` only returns a boolean; `biometric_service.dart:69-84` never maps the credential to a student. `README.md:48-51` states this explicitly |

### 4.4 Local database and offline sync

| Requirement | Result | Evidence |
| --- | --- | --- |
| SQLite opened in WAL mode | **PASS (code)** | `local_database_service.dart:34` `PRAGMA journal_mode = WAL`, `:35` `synchronous = NORMAL`, `:36` `busy_timeout = 5000`, `:37` `foreign_keys = ON`. No test asserts the returned mode is `wal` — see LOW-01 |
| Schema versioning / upgrade path | **PASS** | `local_database_service.dart:9` (`_dbVersion = 4`), `:135-191` migrations 2/3/4; passing test `database version 1 upgrades and backfills local session dates` |
| Roster cached locally for offline Pass Mode | **PASS** | `lecture_guard_providers.dart:269-286` (online refresh then `cacheLectureRoster`, offline fallback `getAlphabeticalRoster`); lectures fall back to cache at `:262-266` |
| Attendance persisted before sync | **PASS** | see 4.3, `lecture_guard_providers.dart:471` before `:481` |
| Ending a session fills every missing student as deterministic `absent` | **PASS** | `local_database_service.dart:398-468` (single transaction, `deterministicAttendanceRecordId`, `ConflictAlgorithm.ignore`, `ended_at` + `is_locked_pass_mode = 0`); passing test `endSession fills only missing students as deterministic absent records` |
| Auto-sync on connectivity change, Wi-Fi or cellular | **PASS** | `sync_engine_service.dart:85-108`, `:110-124` (wifi/ethernet/mobile/vpn), `main.dart:43-44` |
| Batched upload (50/chunk) with per-batch failure isolation | **PASS** | `sync_engine_service.dart:46` (`batchChunkSize = 50`), `:201-225` and `:230-265` (each chunk in its own try/catch, `markRecordsFailed` then continue); passing tests `continues after one records batch exhausts retries`, `a poison session batch does not block later session batches` |
| Retry with backoff | **PASS** | `:351-371` (`maxChunkRetries`, `_retryDelay`), `:81-82` quadratic backoff `500 * attempt^2` ms |
| Offline / unreachable server leaves rows queued instead of losing them | **PASS** | `:179-198` early return with `success: false` and queue intact; tests `connectivity without Supabase reachability leaves rows queued`, `connectivity change from offline to online starts a sync` |
| Concurrent edit during upload stays pending after a stale ack | **PASS** | covered by test `an edit during upload remains pending after the stale ack` (row-version guarded writes at `local_database_service.dart:630-633`) |
| Ended session is submitted (`submitted_to_cloud_at`) only after its records | **PASS** | `sync_engine_service.dart:267-295`; test `submits an ended session after all of its records sync` |
| Background sync registered on both platforms | **PASS (code)** | `background_sync_service.dart` (46 LOC) called from `main.dart:23`; iOS `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes` in `Info.plist:29-32, 58-62`. Actual occurrence scheduling **NOT VERIFIED** on device |
| Completed session history readable offline | **PASS** | `class_history_screen.dart:32-34` and `:134-136` read only `LocalDatabaseService` |

### 4.5 Teacher and admin workflows

| Requirement | Result | Evidence |
| --- | --- | --- |
| Sign-in with email/password and visible errors | **PASS** | `sign_in_screen.dart:69-111`; session stream routing in `auth_gate.dart:25-41` |
| Role-based landing (teacher / admin / student) | **PASS** | `auth_gate.dart:92-107`; unknown role gets an explicit "no school profile" screen |
| Teacher starts a session for their lecture, then launches Pass Mode | **PASS** | `teacher_monitor_screen.dart:53-77` (`startPassModeSession`), `:83-91` (`lockPassMode`), buttons at `:311-336` |
| A class cannot be switched while a session is open | **PASS** | `lecture_guard_providers.dart:288-298` throws unless the active session ended |
| Teacher manual override requires a reason for absent/excused/overriding a biometric check-in | **PASS** | `teacher_override_dialog.dart:32-48`; provider re-validates at `lecture_guard_providers.dart:498-506` (defence in depth, throws `ArgumentError`); 3 passing tests |
| Override records `override_by` = signed-in user | **PASS** | `lecture_guard_providers.dart:507-527`; server-side check `003:40` |
| Ending a session attempts an immediate sync and reports queued state | **PASS** | `lecture_guard_providers.dart:400-420`; UI message `teacher_monitor_screen.dart:116-130` |
| Sync status + pending count visible to the teacher | **PASS** | `teacher_monitor_screen.dart:201-226`, `:267-280` |
| Admin chronic-absenteeism list, filterable by search/grade/date range | **PASS** | `admin_analytics_screen.dart:65-66` (RPC params), `:73-80` (invalid range guard), `:378-428` (filters + clear) |
| Admin paging beyond 1000 rows | **PASS** | `.range(offset, offset + 49)` at `:103` and `:140`, `_pageSize = 50` at `:24`, `_hasMore` from a short page at `:108`; export loops until a short page at `:193-201` |
| CSV export of the filtered list | **PASS** | `:204-248` (`encodeCsvRows` + `share_plus`); formula-injection guard `csv_export_service.dart:3-9` |
| PDF export | **PASS** | `:258-307` (pw.MultiPage + share) |
| Trend chart | **PASS** | `:751-807` (`fl_chart` `LineChart` over `v_student_weekly_attendance`) |
| Admin can change the school-wide "excused counts as attended" setting | **PASS** | server: `003:14-26`, `003:342-346` verified by RPC as admin in my run; client reads it in `lecture_guard_providers.dart:149-157` |
| Teacher cannot change that setting | **PASS** | verified in the DB: teacher `UPDATE` affected `0` rows (also asserted by `rls_test.sql:254-260`) |
| Student sees own attendance summary + history | **PASS** | `student_attendance_screen.dart:30-37`, `:135-178` |

### 4.6 Configuration and security

| Requirement | Result | Evidence |
| --- | --- | --- |
| Supabase URL/key supplied at build time, never committed | **PASS** | `main.dart:12-17` (`String.fromEnvironment`), long explanation screen at `:92-127`; `README.md:13-16`; `env.json` in `.gitignore` |
| App ships only the anon/publishable key; `service_role` never referenced | **PASS** | recursive grep for `service_role` over `flutter_app`, `supabase`, `.github` -> 0 matches; `main.dart:21` uses `publishableKey` |
| No hard-coded JWT / API key in source or docs | **PASS** | grep for `eyJ[A-Za-z0-9_-]{10,}` -> 0 matches |
| No default/backdoor lecturer PIN | **PASS** | grep `2468` over `flutter_app`, `supabase`, `.github`, `README.md` -> 0 matches; `pin_security_service.dart:74-93` forces first-run setup, `:95-103` refuses to overwrite, `:126-129` throws instead of allowing an empty PIN |
| Weak PINs rejected | **PASS** | `pin_security_service.dart:62-72` (non-4-digit, `0000`, `1234`, repeated digits); passing test `PIN setup rejects 1234 and repeated digits` |
| PIN hashed with PBKDF2-HMAC-SHA256, >=100k iterations, 256-bit, random salt | **PASS** | `:29` (`100000`), `:32` (`256` bits), `:106` (16-byte `SecretKeyData.random`), `:239-247` (`Pbkdf2.hmacSha256`), `:108-109` (salt + iteration count stored per PIN); test `stores a 256-bit PBKDF2 hash using at least 100k iterations` |
| Hash comparison is constant-time | **PASS** | `:250-257` |
| PIN changed only with the old PIN, and the salt rotates | **PASS** | `:115-124` + `:105-113`; test `PIN changes require the old PIN and rotate the salt` |
| Brute-force lockout persists across app restarts | **PASS** | `:158-182` persists `failed_attempts`, `lockout_level`, `locked_until` to secure storage; `:184-207`; countdown UI `pin_exit_dialog.dart:184-191`; test `restores ...`/`PIN` suite green |
| Secrets at rest use platform secure storage | **PASS** | `pin_security_service.dart:50-58` (`encryptedSharedPreferences`, iOS `first_unlock`) |
| RLS enabled on every table | **PASS** | `001:178-183`, `003:12` |
| No cross-policy recursion | **PASS** | exercised every table/view as 4 personas in §3.2 with no `42P17` |
| Stated RLS requirement for the two reporting views | **FAIL** | student reads 1 summary row and 8 submission-log rows — see HIGH-02 |
| CI proves the above on every push | **FAIL** | `flutter` job passes locally, but the `supabase-rls` job runs `supabase/tests/rls_test.sql:45-51`, which fails — see HIGH-01 |

---

## 5. Phase 3 — Documentation of the biometric identity limitation

| Required statement | Result | Evidence |
| --- | --- | --- |
| Docs state `local_auth` cannot identify *which* student's finger was used | **PASS** | `README.md:48-51`: "`local_auth` confirms that a fingerprint (or Face ID ...) registered on this device was successfully used. It does **not** identify which student supplied the biometric. Pass Mode therefore remains an assisted attendance workflow; it is not proof of student identity." |
| Docs list *alternative* identity options (what a school should use instead) | **FAIL** | Nothing in `README.md` or `flutter_app/README.md` names an alternative (per-student QR/NFC card, student-held PIN, one-device-per-student, teacher-attested roll-call, rostered face recognition with per-student enrolment). `README.md:53-55` only covers iOS Guided Access. See MEDIUM-02 |
| Docs explain the Android kiosk limitation | **FAIL** | Android is described as "screen pinning" nowhere; the README implies Pass Mode is locked without noting the user can dismiss screen pinning. See MEDIUM-02 |
| Docs state admins/teachers are provisioned out-of-band | **PASS** | `README.md:39-40` |
| Docs give the migration order and setup steps | **PASS** | `README.md:13-37` |

---

## 6. Phase 4 — Manual device checklist (not yet executed)

Nothing in this section has been performed; it is the remaining work needed
before the device-dependent rows above can leave **NOT VERIFIED**.

### 6.1 Android (target API 23+; test at least one API 29- and one API 34-class device)

1. Fresh install -> app shows the PIN setup screen; try `0000`, `1234`, `1111`
   and a 5-digit PIN: all rejected (`PIN setup rejects ...`).
2. Set a PIN, sign in as a teacher, load a lecture with a 300+ roster:
   measure first-frame time and scroll smoothness; confirm the frame budget is
   not exceeded while scrolling fast and while typing in search.
3. Tap "Launch Pass Mode": confirm the immersive UI and that Android asks for
   screen-pinning confirmation ("Pin"/"Got it").
4. Try to leave without the PIN: Back gesture, Home, Recents, notification
   shade, split-screen, and the Recents "Unpin" affordance. Record exactly which
   gestures escape the app (this is the MEDIUM-01 risk).
5. On the roster, tap a student with an enrolled fingerprint: the biometric
   sheet must be biometric-only (no "Use PIN/pattern" fallback). Verify the row
   turns green and becomes non-tappable, and that a second tap does nothing.
6. Tap the same student as a *different* finger of the same device owner: it
   still checks in — record this as the known limitation.
7. With a student who has no enrolment on the device, confirm the
   "Teacher PIN" path appears, and that cancelling it adds no record.
8. Wait past `late_grace_minutes`, check in another student, confirm amber.
9. Five wrong PINs in the exit dialog -> lockout with a live countdown; kill and
   relaunch the app mid-lockout -> lockout still enforced with remaining time.
10. Enable airplane mode, check in 20 students, kill the app, relaunch: all
    records and the lock must be restored (roster, checked-in count).
11. Re-enable data: confirm the pending counter drains and `attendance_sessions`/
    `attendance_records` appear in Supabase with `biometric_verified = true`.
12. Turn on "Do not keep activities" in developer options and repeat 10-11.
13. End the session: every unchecked student must appear as `absent`, and a
    second "End Session" must be refused.
14. Let the screen sleep / receive a call during Pass Mode, then return: the
    screen must re-assert immersive mode and re-request pinning.
15. Battery saver + 30 minutes idle: confirm background/debounced sync still
    drains the queue (WorkManager scheduling).

### 6.2 iPhone / iPad

1. Fresh install -> PIN setup; Face ID permission prompt appears only on the
   first check-in, with the `NSFaceIDUsageDescription` text ("LectureGuard uses
   Face ID to verify a student before recording attendance.").
2. Guarded Access OFF: verify Pass Mode can be backgrounded by the student
   (expected) and that the session/records survive.
3. Enable Settings > Accessibility > Guided Access, start it for LectureGuard,
   then verify the student cannot leave the app at all.
4. Check-in with Face ID: confirm success path and green tile; cover the camera
   / fail 3 times and confirm the "sensor locked" message plus PIN path.
5. Test on a device with no passcode/Face ID enrolled: confirm the app degrades
   to the teacher-PIN path instead of crashing.
6. Airplane-mode check-ins, force-quit, relaunch: records + lock restored.
7. Background fetch: enable Background App Refresh, background the app for 15+
   minutes, confirm pending queue drains (`BGTaskScheduler` identifier
   `com.lectureguard.lectureGuard.backgroundSync`).
8. iPad split view / stage manager: confirm Pass Mode still covers the screen.

---

## 7. Defects, prioritized

### HIGH-01 — The repository's RLS test fails, so CI is red (release blocker)

* **Where:** `supabase/tests/rls_test.sql:204` (expectation), failure raised at
  `:234`; job defined in `.github/workflows/flutter-ci.yml:45-51`.
* **What:** the student block asserts that seeing 4 `attendance_records` is
  wrong, but the correct value for that fixture is **3** (the 4th row belongs to
  student 2). Every assertion after it — teacher matrix, admin matrix, chronic
  page, view-access check — never executes.
* **Proof:** `psql:supabase/tests/rls_test.sql:234: ERROR: student can see rows
  outside their enrolled class`, plus the diagnostic `records_actual = 3` (§3.1).
* **Impact:** the security suite provides no coverage at all in CI, and the
  pipeline cannot go green. "Everything implemented and tested" is not a
  supportable claim.
* **Fix:** add a 4th record for student 1 to the fixture or change the
  expectation to `3`, then re-run and repair whatever the rest of the file
  uncovers once it executes past line 234. Note that `:206` also has to change if
  HIGH-02 is fixed.

### HIGH-02 — Students can read the teacher/admin reporting views (requirement violated)

* **Where:** `supabase/migrations/002_fix_rls_and_views.sql:98-99` and
  `003_school_settings_and_analytics.sql:44-45` (`security_invoker = true` views)
  combined with the student read policies at `002:208, 226, 236-237`; the leak is
  asserted as *expected* at `rls_test.sql:206`.
* **What:** the requirement is "anon **and student** get ZERO rows from
  `v_student_attendance_summary` and `v_teacher_submission_logs`". Measured as
  student 1: `v_summary = 1` row, `v_teacher_logs = 8` rows (§3.2 check 3). Only
  `anon` is actually blocked, and only by `REVOKE` (`002:165-170`,
  `003:229-236`).
* **Impact:** a student can enumerate every session of their class with the
  teacher name, enrolment snapshot and present/absent counts, plus their own
  summary row — wider than the spec, and a confidentiality surface the spec
  explicitly closes.
* **Product tension:** `student_attendance_screen.dart:30-33` *depends* on a
  student reading `v_student_attendance_summary` (`.maybeSingle()`), so a plain
  revoke breaks the student screen. Recommended split: keep the summary view
  readable (it already returns only the caller's row) and revise the requirement
  wording, while revoking `v_teacher_submission_logs` from students — e.g. expose
  it through a `security definer` function that returns rows only when
  `teacher_id = auth.uid()` or `public.current_user_role() = 'admin'`.

### MEDIUM-01 — Android Pass Mode is screen pinning, not a kiosk lock, and this is undocumented

* **Where:** `flutter_app/android/app/src/main/kotlin/com/lectureguard/lecture_guard/MainActivity.kt:19-32`;
  no `setLockTaskPackages`, no device-owner/device-admin component anywhere under
  `flutter_app/android`; `README.md` never mentions it.
* **What:** `startLockTask()` from a non-device-owner app enters
  `LOCK_TASK_MODE_PINNED`, which the user can leave from Recents ("Unpin")
  without any PIN, and the app cannot detect it.
* **Impact:** a determined student can leave the app mid-session. They cannot end
  the session or forge records (state and PIN live in the app), so "locked to
  prevent unauthorised exit" overstates the guarantee.
* **Fix:** document it plainly and/or ship a device-owner/MDM provisioning guide
  (`setLockTaskPackages` + `LOCK_TASK_MODE_LOCKED`) for schools needing a real
  kiosk.

### MEDIUM-02 — README documents the biometric limitation but offers no alternative identity options

* **Where:** `README.md:42-55`.
* **What:** the required disclosure is present and precise (`:48-51`), but the
  document lists no alternative identity mechanism, which the requirement asks
  for explicitly.
* **Fix:** add a short list — per-student QR/NFC card scanned by the same phone,
  student-entered PIN bound to the student id, one device per student, teacher
  attestation, or per-student face enrolment.

### MEDIUM-03 — Assurance gap: a third of the app is untested

* **Where:** coverage artifact `flutter_app/coverage/lcov.info` (§2).
* **What:** 10 shipped files are absent from coverage (0 %): admin analytics,
  teacher monitor, student attendance, class history, lecture picker, sign-in,
  change-PIN, auth gate, background sync and `main.dart`. The real
  `LocalAuthentication.authenticate()` path is 1/24 lines in
  `biometric_service.dart`. The only roster `testWidgets` stubs the network
  engine (`student_pass_mode_test.dart:89-105`), so nothing exercises sync over
  HTTP.
* **Impact:** the highest-risk behaviours (kiosk lock, biometric prompt, batch
  upload, admin paging) have no automated evidence, and no device test was
  possible here.
* **Fix:** add widget tests for the unlock/lockout flow and for
  `AdminAnalyticsScreen` paging against a mocked client; add an integration test
  against a local Supabase stack; then run §6.

### LOW-01 — WAL mode is configured but never asserted

`local_database_service.dart:34` issues `PRAGMA journal_mode = WAL`, but no test
reads the pragma back, so a regression to the default rollback journal would be
silent. Fix: assert `SELECT journal_mode` returns `wal` in
`session_lifecycle_test.dart`.

### LOW-02 — PIN lockout backoff is uncapped

`pin_security_service.dart:173` computes
`_baseLockoutSeconds * (1 << lockoutLevel)` and `:179` increments the level
forever. At level >= 63 the shift overflows negative, producing a past
`locked_until` and skipping the lockout for that attempt. Practically
unreachable (~315 failed attempts, each after an exponentially longer wait) but
trivial to cap.

### LOW-03 — A-Z bar only searches forward

`student_roster.dart:38-46` (`nextAvailableLetter`) walks from the tapped letter
to `Z` only, so tapping a letter after the last populated initial (e.g. `Z` when
the roster ends at `T`) does nothing. Acceptable, but "including empty letters" is
only satisfied in the forward direction.

### LOW-04 — A missing `school_settings` row silently blanks all reporting

`003:84` (`CROSS JOIN public.school_settings`) means deleting the single row makes
`v_student_attendance_summary`, `v_student_weekly_attendance` and
`admin_chronic_absentee_page` return zero rows instead of failing. A `LEFT JOIN`
with `COALESCE(settings.excused_counts_as_attended, FALSE)` would be safer.

### LOW-05 — Local and cloud attendance ids diverge

`attendance_models.dart:291-302` omits `id` from the payload while upserting on
`session_id,student_id`, so the server generates a different id than the
deterministic local id. Nothing reconciles by id today; any future "fetch back by
id" feature would break.

### LOW-06 — Failure to engage screen pinning is only a transient snackbar

`student_pass_mode_screen.dart:96-104` catches the `MethodChannel` failure, shows
a 4-second SnackBar, then continues in a UI that still looks locked. Consider a
persistent warning banner or refusing to enter Pass Mode.

### LOW-07 — Configuration validation is "non-empty string" only

`main.dart:14-17` accepts any non-empty `SUPABASE_URL`/`SUPABASE_ANON_KEY`; a typo
only surfaces later as a network error. Validate the URL scheme at startup.

---

## 8. Verdict

**NOT READY.**

* Build, analysis and the 36 Flutter tests are green (`flutter analyze` clean,
  `flutter test` 36/36, debug APK produced), and the large majority of
  requirement rows pass with file:line evidence.
* Release is blocked by **HIGH-01** (the repo's own RLS test fails, so the
  security job in CI cannot pass) and **HIGH-02** (students can read both
  reporting views, contradicting the stated requirement).
* A second acceptance gate remains: **no device evidence exists** for the
  biometric prompt, the Pass Mode lock, offline restore after force-kill, or
  background sync. §6 must be executed on real Android and iOS hardware before
  sign-off.

Ship-blocking count: **2 HIGH**. Also open: 3 MEDIUM, 7 LOW.

---

## Appendix A — Artifacts and reproduction

| Artifact | Purpose |
| --- | --- |
| `qa/rls_verify.sql` | independent RLS suite: mock auth, all 5 migrations, 9 checks, prints every query result |
| `qa/rls_verify_output.txt` | captured output of the above (exit code 0) |
| `qa/diag_copilot_assertions.sql` | replica of the shipped fixtures that prints the counts `rls_test.sql` asserts |
| `qa/coverage_summary.py` | lcov -> per-folder coverage summary used in §2 |
| `qa/build_apk.log` | full `flutter build apk --debug` transcript |
| `qa/diag_output.txt` | raw output of the fixture diagnostic (§3.1) |

```powershell
# Flutter
cd flutter_app; flutter pub get; flutter analyze; flutter test --coverage; flutter build apk --debug

# Database (any PostgreSQL 16; docker or local)
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55432 -U postgres -d postgres -f qa/rls_verify.sql
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55432 -U postgres -d postgres -f supabase/tests/rls_test.sql   # passes (see Appendix B)

# Coverage report
python qa/coverage_summary.py flutter_app/coverage/lcov.info
```

---

## Appendix B — Remediation verification (2026-11-21)

This appendix records the state after the defects in §7 were addressed. The
verdict in §0/§8 describes the **pre-remediation** snapshot; every result below
was re-executed on the same environment (Flutter 3.44.6 / Dart 3.12.2,
PostgreSQL 16.16, throwaway cluster on `127.0.0.1:55432`).

### B.1 Current command results

| Check | Command | Result |
| --- | --- | --- |
| Static analysis | `flutter analyze --no-pub` | **PASS** — `No issues found!` |
| Test suite | `flutter test --coverage --no-pub` | **PASS** — `01:59 +57: All tests passed!` (57 tests, 13 files) |
| Coverage | `python qa/coverage_summary.py` | 1390/2557 lines = **54.4 %** over 25 files (the measured surface is larger than in §2; see MEDIUM-03 below) |
| Repository RLS suite | `psql -f supabase/tests/rls_test.sql` | **PASS** — `rls_test.sql passed`, exit 0 |
| Independent RLS suite | `psql -f qa/rls_verify.sql` | **PASS** — `rls_verify.sql completed without aborting`, exit 0; output regenerated in `qa/rls_verify_output.txt` |
| Debug APK | `flutter build apk --debug --no-pub` | **PASS** — `Built build\app\outputs\flutter-apk\app-debug.apk` (643 s) |
| Default-PIN regression | `node qa/no_default_pin_regression.test.mjs` | **PASS** — `PASS: missing, invalid, and unreadable PIN state has no default PIN` |

### B.2 Defect status

| Defect | Status | Change and evidence |
| --- | --- | --- |
| HIGH-01 | **Fixed** | The `rls_test.sql` fixture expectation was corrected and the later blocks repaired. The suite now runs past line 234 and ends with `rls_test.sql passed` (exit 0), so the `supabase-rls` CI job has assertions again. |
| HIGH-02 | **Fixed** | `004_harden_teacher_submission_logs.sql` revokes the view from clients and exposes a staff-only `teacher_submission_logs(p_limit, p_offset)` RPC. Re-measured: student rows from the RPC = **0**, teacher rows = 8 for their own course only. The summary view intentionally stays readable but returns only the caller's own row (1 row for student 1), matching the documented split. |
| MEDIUM-01 | **Fixed (documented + UI)** | README §"Pass Mode device lockdown" separates screen pinning from device-owner kiosk mode and gives an MDM recipe. `MainActivity.kt` now reports the granted lock level, and Pass Mode keeps a persistent warning banner whenever the lock did not engage. |
| MEDIUM-02 | **Fixed (documented)** | README §"Student identity options" lists per-student QR/NFC cards, student-bound PINs, BYOD, teacher attestation and per-student face enrolment, and states that only teacher attestation is implemented. |
| MEDIUM-03 | **Partially addressed** | Tests grew from 36 to 57 and now cover admin paging against a mocked Supabase client, PIN lockout + exit dialog, configuration validation, WAL, roster sort/search/A-Z, teacher overrides, CSV formula escaping, lecture picker and auth routing. `teacher_monitor_screen.dart`, `class_history_screen.dart` and `change_lecturer_pin_screen.dart` are still at 0–1 %, and no device or local-Supabase integration test exists, so the hardware gates in §6 still apply. |
| LOW-01 | **Fixed** | `local_database_test.dart` opens a file-backed database and asserts `PRAGMA journal_mode` returns `wal`. |
| LOW-02 | **Fixed** | `pin_security_service.dart` caps the backoff exponent at 7 and the duration at 3600 s. Two tests cover twelve lockout rounds and a corrupted level of 99; both end at exactly one hour. |
| LOW-03 | **Fixed** | `nextAvailableLetter` now walks backwards when no populated letter exists at or after the tapped one; `A-Z bar falls back to the nearest previous letter` passes. |
| LOW-04 | **Fixed** | `005_school_settings_left_join.sql` replaces the `CROSS JOIN` with `LEFT JOIN ... ON settings.id = 1` plus `COALESCE(settings.excused_counts_as_attended, FALSE)` in both views and `admin_chronic_absentee_page`. CHECK 9 deletes the row and still returns 2 summary rows, 3 weekly rows, 5 attended sessions for STU-1 and 1 chronic-absence row. |
| LOW-05 | **Fixed** | `AttendanceRecord.toSupabasePayload()` now sends the deterministic `id`, and `SyncEngineService` upserts with `onConflict: 'id'`; `attendance record upserts send the deterministic id and conflict on it` passes. |
| LOW-06 | **Fixed** | Pass Mode no longer relies on a transient SnackBar: a failed `startLockTask` leaves a persistent warning banner for the whole session. Widget tests cover both the warned and the genuinely locked kiosk states. |
| LOW-07 | **Fixed** | `validateSupabaseConfiguration` in `main.dart` rejects missing values, non-`https` URLs and host-less URLs; `main_config_test.dart` covers each case. |

### B.3 Remaining work

* Execute §6 on real Android and iOS hardware: biometric prompt, screen
  pinning / kiosk, iOS Guided Access, force-kill restore and background sync.
* Raise coverage for the remaining screens (`teacher_monitor_screen.dart`,
  `class_history_screen.dart`, `change_lecturer_pin_screen.dart`) and add an
  integration test against a local Supabase stack.
