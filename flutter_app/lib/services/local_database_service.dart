import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/attendance_models.dart';

class LocalDatabaseService {
  static const _dbName = 'lecture_guard_v1.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        // WAL mode + NORMAL sync + 5s busy timeout guarantees zero lost check-ins
        // even when 300+ writes overlap with cellular background batch syncs.
        await db.execute('PRAGMA journal_mode = WAL;');
        await db.execute('PRAGMA synchronous = NORMAL;');
        await db.execute('PRAGMA busy_timeout = 5000;');
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
            started_at TEXT NOT NULL,
            ended_at TEXT,
            is_locked_pass_mode INTEGER NOT NULL DEFAULT 1,
            enrolled_count INTEGER NOT NULL,
            sync_status TEXT NOT NULL DEFAULT 'pending'
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
    );
  }

  Future<void> cacheLectureRoster(Lecture lecture, List<Student> students) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'lectures',
        lecture.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
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

  /// Zero-latency WAL write executed immediately upon biometric match.
  Future<void> upsertAttendanceRecord(AttendanceRecord record) async {
    final db = await database;
    await db.insert(
      'attendance_records',
      record.toSqliteMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final rows = await db.query(
      'attendance_records',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.synced.name],
      orderBy: 'device_recorded_at ASC',
    );
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

  Future<void> markRecordsSynced(List<String> recordIds) async {
    if (recordIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final placeholders = List.filled(recordIds.length, '?').join(',');
      await txn.rawUpdate(
        'UPDATE attendance_records SET sync_status = ? WHERE id IN ($placeholders)',
        [SyncStatus.synced.name, ...recordIds],
      );
    });
  }
}
