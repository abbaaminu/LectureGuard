import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/attendance_models.dart';
import 'session_ids.dart';

class LocalDatabaseService {
  static const _dbName = 'lecture_guard_v1.db';
  static const _dbVersion = 3;

  final DatabaseFactory _databaseFactory;
  final String? _databasePath;
  Database? _db;

  LocalDatabaseService({DatabaseFactory? factory, String? databasePath})
      : _databaseFactory = factory ?? databaseFactory,
        _databasePath = databasePath;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final path = _databasePath ??
        join(await _databaseFactory.getDatabasesPath(), _dbName);

    return _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL;');
          await db.execute('PRAGMA synchronous = NORMAL;');
          await db.rawQuery('PRAGMA busy_timeout = 5000;');
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE students (
            id TEXT PRIMARY KEY,
            student_code TEXT NOT NULL UNIQUE,
            first_name TEXT NOT NULL,
            last_name TEXT NOT NULL,
            grade_level INTEGER NOT NULL,
            homeroom TEXT NOT NULL
          );
          ''');

          await db.execute('''
          CREATE TABLE lectures (
            id TEXT PRIMARY KEY,
            course_code TEXT NOT NULL,
            title TEXT NOT NULL,
            teacher_id TEXT NOT NULL,
            teacher_name TEXT NOT NULL,
            room_number TEXT NOT NULL,
            period_number INTEGER NOT NULL,
            late_grace_minutes INTEGER NOT NULL DEFAULT 10
          );
          ''');

          await db.execute('''
          CREATE TABLE enrollments (
            lecture_id TEXT NOT NULL,
            student_id TEXT NOT NULL,
            PRIMARY KEY (lecture_id, student_id)
          );
          ''');

          await db.execute('''
          CREATE TABLE attendance_sessions (
            id TEXT PRIMARY KEY,
            lecture_id TEXT NOT NULL,
            teacher_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            session_date TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            is_locked_pass_mode INTEGER NOT NULL DEFAULT 1,
            enrolled_count INTEGER NOT NULL,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_retry_at TEXT,
            submitted_to_cloud_at TEXT,
            submitted_to_cloud_synced INTEGER NOT NULL DEFAULT 0
          );
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
            row_version INTEGER NOT NULL DEFAULT 1,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_retry_at TEXT,
            UNIQUE(session_id, student_id)
          );
          ''');

          await db.execute(
            'CREATE INDEX idx_students_alpha ON students(last_name COLLATE NOCASE, first_name COLLATE NOCASE);',
          );
          await db.execute(
            'CREATE INDEX idx_records_sync ON attendance_records(sync_status, device_recorded_at);',
          );
          await db.execute(
            'CREATE INDEX idx_records_session ON attendance_records(session_id);',
          );
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE attendance_sessions ADD COLUMN device_id TEXT NOT NULL DEFAULT '';",
            );
            await db.execute(
              "ALTER TABLE attendance_sessions ADD COLUMN session_date TEXT NOT NULL DEFAULT '';",
            );
            await db.execute(
              "UPDATE attendance_sessions SET session_date = substr(started_at, 1, 10) WHERE session_date = '';",
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              "ALTER TABLE attendance_sessions ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;",
            );
            await db.execute(
              'ALTER TABLE attendance_sessions ADD COLUMN last_error TEXT;',
            );
            await db.execute(
              'ALTER TABLE attendance_sessions ADD COLUMN next_retry_at TEXT;',
            );
            await db.execute(
              'ALTER TABLE attendance_sessions ADD COLUMN submitted_to_cloud_at TEXT;',
            );
            await db.execute(
              'ALTER TABLE attendance_sessions ADD COLUMN submitted_to_cloud_synced INTEGER NOT NULL DEFAULT 0;',
            );
            await db.execute(
              'ALTER TABLE attendance_records ADD COLUMN row_version INTEGER NOT NULL DEFAULT 1;',
            );
            await db.execute(
              'ALTER TABLE attendance_records ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;',
            );
            await db.execute(
              'ALTER TABLE attendance_records ADD COLUMN last_error TEXT;',
            );
            await db.execute(
              'ALTER TABLE attendance_records ADD COLUMN next_retry_at TEXT;',
            );
          }
        },
      ),
    );
  }

  Future<void> close() async {
    final db = _db;
    if (db == null) return;
    await db.close();
    _db = null;
  }

  Future<void> cacheLectureRoster(
      Lecture lecture, List<Student> students) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'lectures',
        lecture.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'enrollments',
        where: 'lecture_id = ?',
        whereArgs: [lecture.id],
      );
      final batch = txn.batch();
      for (final student in students) {
        batch.insert(
          'students',
          student.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        batch.insert(
          'enrollments',
          {'lecture_id': lecture.id, 'student_id': student.id},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> cacheLectures(List<Lecture> lectures) async {
    final db = await database;
    final batch = db.batch();
    for (final lecture in lectures) {
      batch.insert(
        'lectures',
        lecture.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Lecture>> getCachedLectures({String? teacherId}) async {
    final db = await database;
    final rows = await db.query(
      'lectures',
      where: teacherId == null ? null : 'teacher_id = ?',
      whereArgs: teacherId == null ? null : [teacherId],
      orderBy: 'period_number ASC',
    );
    return rows.map(Lecture.fromMap).toList();
  }

  Future<Lecture?> getCachedLecture(String lectureId) async {
    final db = await database;
    final rows = await db.query(
      'lectures',
      where: 'id = ?',
      whereArgs: [lectureId],
      limit: 1,
    );
    return rows.isEmpty ? null : Lecture.fromMap(rows.first);
  }

  Future<List<Student>> getAlphabeticalRoster(String lectureId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.* FROM students s
      INNER JOIN enrollments e ON e.student_id = s.id
      WHERE e.lecture_id = ?
      ORDER BY s.last_name COLLATE NOCASE ASC, s.first_name COLLATE NOCASE ASC
    ''', [lectureId]);
    return rows.map(Student.fromMap).toList();
  }

  Future<void> upsertSession(AttendanceSession session) async {
    final db = await database;
    await db.insert(
      'attendance_sessions',
      {...session.toMap(), 'sync_status': SyncStatus.pending.name},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<AttendanceSession> createSessionIfAbsent(
    AttendanceSession session,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      await txn.insert(
        'attendance_sessions',
        {...session.toMap(), 'sync_status': SyncStatus.pending.name},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final rows = await txn.query(
        'attendance_sessions',
        where: 'id = ?',
        whereArgs: [session.id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Could not create or restore attendance session.');
      }
      return AttendanceSession.fromMap(rows.first);
    });
  }

  Future<AttendanceSession?> getActiveSession(String teacherId) async {
    final db = await database;
    final rows = await db.query(
      'attendance_sessions',
      where: 'teacher_id = ? AND ended_at IS NULL',
      whereArgs: [teacherId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : AttendanceSession.fromMap(rows.first);
  }

  Future<void> setSessionPassModeLocked(
    String sessionId, {
    required bool isLocked,
  }) async {
    final db = await database;
    final updated = await db.update(
      'attendance_sessions',
      {
        'is_locked_pass_mode': isLocked ? 1 : 0,
        'sync_status': SyncStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'next_retry_at': null,
      },
      where: 'id = ? AND ended_at IS NULL',
      whereArgs: [sessionId],
    );
    if (updated != 1) {
      throw StateError('The attendance session is no longer active.');
    }
  }

  Future<AttendanceSession> endSession(String sessionId) async {
    final db = await database;
    return db.transaction((txn) async {
      final sessionRows = await txn.query(
        'attendance_sessions',
        where: 'id = ?',
        whereArgs: [sessionId],
        limit: 1,
      );
      if (sessionRows.isEmpty) {
        throw StateError('Attendance session $sessionId was not found.');
      }
      final session = AttendanceSession.fromMap(sessionRows.first);
      if (session.endedAt != null) return session;

      final rosterRows = await txn.rawQuery('''
        SELECT s.id
        FROM students AS s
        INNER JOIN enrollments AS e ON e.student_id = s.id
        WHERE e.lecture_id = ?
      ''', [session.lectureId]);
      final recordedRows = await txn.query(
        'attendance_records',
        columns: ['student_id'],
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      final recordedStudentIds =
          recordedRows.map((row) => row['student_id'] as String).toSet();
      final endedAt = DateTime.now();
      final batch = txn.batch();
      for (final row in rosterRows) {
        final studentId = row['id'] as String;
        if (recordedStudentIds.contains(studentId)) continue;
        final record = AttendanceRecord(
          id: deterministicAttendanceRecordId(sessionId, studentId),
          sessionId: sessionId,
          lectureId: session.lectureId,
          studentId: studentId,
          status: AttendanceStatus.absent,
          syncStatus: SyncStatus.pending,
          deviceRecordedAt: endedAt,
        );
        batch.insert(
          'attendance_records',
          record.toSqliteMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      await txn.update(
        'attendance_sessions',
        {
          'ended_at': endedAt.toIso8601String(),
          'is_locked_pass_mode': 0,
          'sync_status': SyncStatus.pending.name,
          'attempt_count': 0,
          'last_error': null,
          'next_retry_at': null,
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      final endedRows = await txn.query(
        'attendance_sessions',
        where: 'id = ?',
        whereArgs: [sessionId],
        limit: 1,
      );
      return AttendanceSession.fromMap(endedRows.single);
    });
  }

  /// Zero-latency WAL write executed immediately upon biometric match.
  Future<void> upsertAttendanceRecord(AttendanceRecord record) async {
    final db = await database;
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'attendance_records',
        columns: ['row_version'],
        where: 'id = ? OR (session_id = ? AND student_id = ?)',
        whereArgs: [record.id, record.sessionId, record.studentId],
        limit: 1,
      );
      final rowVersion = existingRows.isEmpty
          ? 1
          : (existingRows.first['row_version'] as int) + 1;
      await txn.insert(
        'attendance_records',
        {
          ...record.toSqliteMap(),
          'row_version': rowVersion,
          'attempt_count': 0,
          'last_error': null,
          'next_retry_at': null,
          'sync_status': SyncStatus.pending.name,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<AttendanceRecord>> getSessionRecords(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'attendance_records',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  Future<List<AttendanceRecord>> getPendingSyncRecords() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT r.*
      FROM attendance_records AS r
      INNER JOIN attendance_sessions AS s ON s.id = r.session_id
      WHERE r.sync_status != ?
        AND s.sync_status = ?
        AND (r.next_retry_at IS NULL OR r.next_retry_at <= ?)
      ORDER BY r.device_recorded_at ASC
    ''', [
      SyncStatus.synced.name,
      SyncStatus.synced.name,
      DateTime.now().toUtc().toIso8601String(),
    ]);
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  Future<int> getPendingSyncCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM attendance_records WHERE sync_status != ?',
      [SyncStatus.synced.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<AttendanceSession>> getPendingSyncSessions() async {
    final db = await database;
    final rows = await db.query(
      'attendance_sessions',
      where:
          'sync_status != ? AND (next_retry_at IS NULL OR next_retry_at <= ?)',
      whereArgs: [
        SyncStatus.synced.name,
        DateTime.now().toUtc().toIso8601String(),
      ],
      orderBy: 'started_at ASC',
    );
    return rows.map(AttendanceSession.fromMap).toList();
  }

  Future<int> getPendingSyncWorkCount() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM attendance_records WHERE sync_status != ?) +
        (SELECT COUNT(*) FROM attendance_sessions WHERE sync_status != ?) +
        (SELECT COUNT(*) FROM attendance_sessions
          WHERE submitted_to_cloud_at IS NOT NULL
            AND submitted_to_cloud_synced = 0) AS cnt
    ''', [SyncStatus.synced.name, SyncStatus.synced.name]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> markSessionsSynced(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final sessionId in sessionIds) {
        await txn.update(
          'attendance_sessions',
          {
            'sync_status': SyncStatus.synced.name,
            'attempt_count': 0,
            'last_error': null,
            'next_retry_at': null,
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      }
    });
  }

  Future<void> markSessionsFailed(
    List<String> sessionIds,
    String error,
  ) async {
    if (sessionIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final sessionId in sessionIds) {
        final rows = await txn.query(
          'attendance_sessions',
          columns: ['attempt_count'],
          where: 'id = ?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final attemptCount = (rows.first['attempt_count'] as int) + 1;
        await txn.update(
          'attendance_sessions',
          {
            'sync_status': SyncStatus.failed.name,
            'attempt_count': attemptCount,
            'last_error': error,
            'next_retry_at': _nextRetryAt(attemptCount),
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      }
    });
  }

  Future<int> markRecordsSynced(List<AttendanceRecord> records) async {
    if (records.isEmpty) return 0;
    final db = await database;
    return db.transaction((txn) async {
      var markedCount = 0;
      for (final record in records) {
        markedCount += await txn.update(
          'attendance_records',
          {
            'sync_status': SyncStatus.synced.name,
            'attempt_count': 0,
            'last_error': null,
            'next_retry_at': null,
            'row_version': record.rowVersion + 1,
          },
          where: 'id = ? AND row_version = ?',
          whereArgs: [record.id, record.rowVersion],
        );
      }
      return markedCount;
    });
  }

  Future<void> markRecordsFailed(
    List<AttendanceRecord> records,
    String error,
  ) async {
    if (records.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final record in records) {
        final attemptCount = record.attemptCount + 1;
        await txn.update(
          'attendance_records',
          {
            'sync_status': SyncStatus.failed.name,
            'attempt_count': attemptCount,
            'last_error': error,
            'next_retry_at': _nextRetryAt(attemptCount),
            'row_version': record.rowVersion + 1,
          },
          where: 'id = ? AND row_version = ?',
          whereArgs: [record.id, record.rowVersion],
        );
      }
    });
  }

  Future<void> prepareEndedSessionsForSubmission() async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery('''
        SELECT s.id
        FROM attendance_sessions AS s
        WHERE s.ended_at IS NOT NULL
          AND s.sync_status = ?
          AND s.submitted_to_cloud_at IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM attendance_records AS r
            WHERE r.session_id = s.id
              AND r.sync_status != ?
          )
      ''', [SyncStatus.synced.name, SyncStatus.synced.name]);
      final submittedAt = DateTime.now().toUtc().toIso8601String();
      for (final row in rows) {
        await txn.update(
          'attendance_sessions',
          {'submitted_to_cloud_at': submittedAt},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
  }

  Future<List<Map<String, Object?>>>
      getPendingSessionSubmissionUpdates() async {
    final db = await database;
    return db.query(
      'attendance_sessions',
      columns: ['id', 'submitted_to_cloud_at'],
      where: 'submitted_to_cloud_at IS NOT NULL AND '
          'submitted_to_cloud_synced = 0 AND '
          '(next_retry_at IS NULL OR next_retry_at <= ?)',
      whereArgs: [DateTime.now().toUtc().toIso8601String()],
    );
  }

  Future<void> markSessionSubmissionSynced(
    String sessionId,
    String submittedAt,
  ) async {
    final db = await database;
    await db.update(
      'attendance_sessions',
      {'submitted_to_cloud_synced': 1},
      where: 'id = ? AND submitted_to_cloud_at = ?',
      whereArgs: [sessionId, submittedAt],
    );
  }

  String _nextRetryAt(int attemptCount) {
    final exponent = attemptCount < 1
        ? 0
        : attemptCount > 7
            ? 6
            : attemptCount - 1;
    final delaySeconds = 60 * (1 << exponent);
    return DateTime.now()
        .toUtc()
        .add(Duration(seconds: delaySeconds))
        .toIso8601String();
  }
}
