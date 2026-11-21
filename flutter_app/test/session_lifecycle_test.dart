import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/session_ids.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';

void main() {
  late LocalDatabaseService database;

  const lecture = Lecture(
    id: 'lecture-1',
    courseCode: 'BIO-101',
    title: 'Biology',
    teacherId: 'teacher-1',
    teacherName: 'Teacher',
    roomNumber: 'A1',
    periodNumber: 1,
  );
  const studentOne = Student(
    id: 'student-1',
    studentCode: 'STU-1',
    firstName: 'Amina',
    lastName: 'Bello',
    gradeLevel: 10,
    homeroom: '10A',
  );
  const studentTwo = Student(
    id: 'student-2',
    studentCode: 'STU-2',
    firstName: 'Zainab',
    lastName: 'Yusuf',
    gradeLevel: 10,
    homeroom: '10A',
  );
  final startedAt = DateTime.now();
  final sessionDate = localSessionDate(startedAt);
  final session = AttendanceSession(
    id: deterministicSessionId(lecture.id, sessionDate),
    lectureId: lecture.id,
    teacherId: lecture.teacherId,
    deviceId: 'device-1',
    sessionDate: sessionDate,
    startedAt: startedAt,
    isLockedPassMode: true,
    enrolledCount: 2,
  );
  final presentRecord = AttendanceRecord(
    id: deterministicAttendanceRecordId(session.id, studentOne.id),
    sessionId: session.id,
    lectureId: lecture.id,
    studentId: studentOne.id,
    status: AttendanceStatus.present,
    biometricVerified: true,
    biometricMethod: 'fingerprint',
    checkedInAt: startedAt,
    deviceRecordedAt: startedAt,
  );

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    await database.cacheLectureRoster(lecture, [studentOne, studentTwo]);
    await database.createSessionIfAbsent(session);
    await database.upsertAttendanceRecord(presentRecord);
  });

  tearDown(() async {
    await database.close();
  });

  test('restores active session, roster, lock, and records from SQLite',
      () async {
    final sync = _OfflineSyncEngine(database);
    final notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      sync,
    );
    await notifier.initialization;

    await notifier.restoreActiveSession(lecture.teacherId);

    expect(notifier.state.activeLecture?.id, lecture.id);
    expect(notifier.state.activeSession?.id, session.id);
    expect(notifier.state.activeSession?.isLockedPassMode, isTrue);
    expect(notifier.state.roster.map((student) => student.id),
        [studentOne.id, studentTwo.id]);
    expect(
        notifier.state.recordsByStudentId[studentOne.id]?.id, presentRecord.id);
    expect(notifier.state.isRestoring, isFalse);
    notifier.dispose();
    sync.dispose();
  });

  test('absent count follows the school-wide excused attendance setting', () {
    final excusedRecord = presentRecord.copyWith(
      status: AttendanceStatus.excused,
    );
    final secondRecord = AttendanceRecord(
      id: deterministicAttendanceRecordId(session.id, studentTwo.id),
      sessionId: session.id,
      lectureId: lecture.id,
      studentId: studentTwo.id,
      status: AttendanceStatus.present,
      deviceRecordedAt: startedAt,
    );
    final state = SessionState(
      roster: [studentOne, studentTwo],
      recordsByStudentId: {
        studentOne.id: excusedRecord,
        studentTwo.id: secondRecord,
      },
    );

    expect(state.absentCount, 1);
    expect(
      state.copyWith(excusedCountsAsAttended: true).absentCount,
      0,
    );
  });

  test('ignores late connectivity updates after notifier disposal', () async {
    final sync = _CallbackSyncEngine(database);
    final notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      sync,
    );
    await notifier.initialization;
    notifier.dispose();

    expect(
      () => sync.connectivityCallback!(NetworkTransport.wifi),
      returnsNormally,
    );
    sync.dispose();
  });

  test('restarting the same lecture on the same day reuses its session',
      () async {
    final sync = _OfflineSyncEngine(database);
    final notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      sync,
    );
    await notifier.initialization;

    await notifier.startPassModeSession(
      lecture: lecture,
      students: [studentOne, studentTwo],
    );

    final rows = await (await database.database).query('attendance_sessions');
    expect(rows, hasLength(1));
    expect(notifier.state.activeSession?.id, session.id);
    expect(
        notifier.state.recordsByStudentId[studentOne.id]?.id, presentRecord.id);
    notifier.dispose();
    sync.dispose();
  });

  test('endSession fills only missing students as deterministic absent records',
      () async {
    final sync = _OfflineSyncEngine(database);
    final notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      sync,
    );
    await notifier.initialization;
    await notifier.restoreActiveSession(lecture.teacherId);

    final result = await notifier.endSession();

    final records = await database.getSessionRecords(session.id);
    final absent = records.singleWhere(
      (record) => record.studentId == studentTwo.id,
    );
    final ended = await database.getActiveSession(lecture.teacherId);
    final pendingSessions = await database.getPendingSyncSessions();
    expect(records, hasLength(2));
    expect(absent.status, AttendanceStatus.absent);
    expect(
      absent.id,
      deterministicAttendanceRecordId(session.id, studentTwo.id),
    );
    expect(
      records.singleWhere((record) => record.studentId == studentOne.id).id,
      presentRecord.id,
    );
    expect(ended, isNull);
    expect(pendingSessions.single.endedAt, isNotNull);
    expect(pendingSessions.single.isLockedPassMode, isFalse);
    expect(notifier.state.activeSession?.endedAt, isNotNull);
    expect(notifier.state.activeSession?.isLockedPassMode, isFalse);
    expect(notifier.state.pendingSyncCount, 2);
    expect(sync.syncCalls, 1);
    expect(result.success, isFalse);
    final history = await database.getLectureHistory(lecture.id);
    expect(history, hasLength(1));
    expect(history.single['recorded_count'], 2);
    final historyRecords = await database.getSessionHistoryRecords(session.id);
    expect(historyRecords, hasLength(2));
    expect(historyRecords.map((record) => record['status']),
        containsAll(['present', 'absent']));
    notifier.dispose();
    sync.dispose();
  });

  test('local school setting defaults to false and persists updates', () async {
    expect(
        (await database.getSchoolSettings()).excusedCountsAsAttended, isFalse);

    await database.cacheSchoolSettings(
      const SchoolSettings(excusedCountsAsAttended: true),
    );

    expect(
        (await database.getSchoolSettings()).excusedCountsAsAttended, isTrue);
  });

  test('override actor and reason persist locally and in sync payload',
      () async {
    final overridden = AttendanceRecord(
      id: presentRecord.id,
      sessionId: session.id,
      lectureId: lecture.id,
      studentId: studentOne.id,
      status: AttendanceStatus.absent,
      overrideReason: 'Teacher correction',
      overrideBy: 'teacher-profile',
      deviceRecordedAt: startedAt,
    );
    await database.upsertAttendanceRecord(overridden);

    final persisted = (await database.getSessionRecords(session.id)).single;
    expect(persisted.overrideBy, 'teacher-profile');
    expect(persisted.overrideReason, 'Teacher correction');
    expect(overridden.toSupabasePayload()['override_by'], 'teacher-profile');
  });

  test('deterministic IDs remain stable for the same local-day inputs',
      () async {
    expect(
      deterministicSessionId(lecture.id, session.sessionDate),
      session.id,
    );
    expect(
      deterministicSessionId(
        lecture.id,
        localSessionDate(startedAt.add(const Duration(days: 1))),
      ),
      isNot(session.id),
    );
    expect(
      deterministicAttendanceRecordId(session.id, studentOne.id),
      presentRecord.id,
    );
    expect(
      deterministicAttendanceRecordId(session.id, studentTwo.id),
      isNot(presentRecord.id),
    );
  });

  test('roster refresh removes enrollments that are no longer assigned',
      () async {
    await database.cacheLectureRoster(lecture, [studentOne]);

    expect(
      (await database.getAlphabeticalRoster(lecture.id))
          .map((student) => student.id),
      [studentOne.id],
    );
  });

  test('local database returns a diacritic-insensitive sorted roster',
      () async {
    const accentStudent = Student(
      id: 'student-accent',
      studentCode: 'STU-ACCENT',
      firstName: 'Elodie',
      lastName: 'Éclair',
      gradeLevel: 10,
      homeroom: '10A',
    );
    await database.cacheLectureRoster(
      lecture,
      [studentTwo, studentOne, accentStudent],
    );

    expect(
      (await database.getAlphabeticalRoster(lecture.id))
          .map((student) => student.id),
      [studentOne.id, accentStudent.id, studentTwo.id],
    );
  });

  test('database version 1 upgrades and backfills local session dates',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('lectureguard-db-upgrade-');
    final path = p.join(directory.path, 'legacy.db');
    final oldDatabase = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE attendance_sessions (
              id TEXT PRIMARY KEY,
              lecture_id TEXT NOT NULL,
              teacher_id TEXT NOT NULL,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              is_locked_pass_mode INTEGER NOT NULL DEFAULT 1,
              enrolled_count INTEGER NOT NULL,
              sync_status TEXT NOT NULL DEFAULT 'pending'
            )
          ''');
          await db.execute('''
              CREATE TABLE attendance_records (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                lecture_id TEXT NOT NULL,
                student_id TEXT NOT NULL,
                status TEXT NOT NULL,
                checked_in_at TEXT,
                biometric_verified INTEGER NOT NULL DEFAULT 0,
                biometric_method TEXT,
                override_reason TEXT,
                sync_status TEXT NOT NULL DEFAULT 'pending',
                device_recorded_at TEXT NOT NULL,
                UNIQUE(session_id, student_id)
              )
            ''');
          await db.insert('attendance_sessions', {
            'id': session.id,
            'lecture_id': lecture.id,
            'teacher_id': lecture.teacherId,
            'started_at': startedAt.toIso8601String(),
            'enrolled_count': 2,
          });
        },
      ),
    );
    await oldDatabase.close();

    final migrated = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    try {
      final upgradedDatabase = await migrated.database;
      final columns = await upgradedDatabase.rawQuery(
        'PRAGMA table_info(attendance_sessions)',
      );
      final recordColumns = await upgradedDatabase.rawQuery(
        'PRAGMA table_info(attendance_records)',
      );
      final sessionRow = (await upgradedDatabase.query(
        'attendance_sessions',
        where: 'id = ?',
        whereArgs: [session.id],
      ))
          .single;

      expect(
        columns.map((column) => column['name']),
        containsAll([
          'device_id',
          'session_date',
          'submitted_to_cloud_at',
          'submitted_to_cloud_synced',
        ]),
      );
      expect(
        recordColumns.map((column) => column['name']),
        containsAll([
          'row_version',
          'attempt_count',
          'last_error',
          'next_retry_at',
          'override_by',
        ]),
      );
      final settingsRow =
          await upgradedDatabase.query('school_settings', where: 'id = 1');
      expect(settingsRow.single['excused_counts_as_attended'], 0);
      expect(
        sessionRow['session_date'],
        localSessionDate(DateTime.parse(sessionRow['started_at'] as String)),
      );
    } finally {
      await migrated.close();
      await directory.delete(recursive: true);
    }
  });
}

class _OfflineSyncEngine extends SyncEngineService {
  final LocalDatabaseService database;
  int syncCalls = 0;

  _OfflineSyncEngine(this.database)
      : super(
          database,
          SupabaseClient('https://example.supabase.co', 'test-key'),
        );

  @override
  Future<NetworkTransport> currentTransport() async => NetworkTransport.offline;

  @override
  void startAutoSyncListener({
    void Function(NetworkTransport transport)? onConnectivityChanged,
    void Function(SyncProgress progress)? onBatchProgress,
    void Function(SyncResult result)? onSyncComplete,
  }) {}

  @override
  Future<SyncResult> syncPendingRecords({
    void Function(SyncProgress progress)? onBatchProgress,
  }) async {
    syncCalls++;
    return SyncResult(
      uploadedCount: 0,
      remainingPendingCount: await database.getPendingSyncCount(),
      batchesCompleted: 0,
      success: false,
      transport: NetworkTransport.offline,
      error: 'Device offline.',
    );
  }
}

class _CallbackSyncEngine extends SyncEngineService {
  void Function(NetworkTransport transport)? connectivityCallback;

  _CallbackSyncEngine(LocalDatabaseService database)
      : super(
          database,
          SupabaseClient('https://example.supabase.co', 'test-key'),
        );

  @override
  Future<NetworkTransport> currentTransport() async => NetworkTransport.offline;

  @override
  void startAutoSyncListener({
    void Function(NetworkTransport transport)? onConnectivityChanged,
    void Function(SyncProgress progress)? onBatchProgress,
    void Function(SyncResult result)? onSyncComplete,
  }) {
    connectivityCallback = onConnectivityChanged;
  }
}
