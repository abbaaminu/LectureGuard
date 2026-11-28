import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/attendance_models.dart';
import 'student_roster.dart';
import 'session_ids.dart';

class LocalDatabaseService {
  static const _dbName = 'lecture_guard_v1.db';
  static const _dbVersion = 10;

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

  Future<void> savePendingTeacherEnrollment({
    required String lectureId,
    required String teacherId,
    required Student student,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'students',
        student.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'enrollments',
        {'lecture_id': lectureId, 'student_id': student.id},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'pending_teacher_enrollments',
        {
          'lecture_id': lectureId,
          'student_id': student.id,
          'teacher_id': teacherId,
          'last_error': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<Map<String, Object?>>> getPendingTeacherEnrollments(
    String teacherId,
  ) async {
    final db = await database;
    return db.rawQuery('''
      SELECT pending.lecture_id, pending.student_id, pending.teacher_id,
             students.student_code, students.first_name, students.last_name,
             students.grade_level, students.homeroom
      FROM pending_teacher_enrollments AS pending
      INNER JOIN students ON students.id = pending.student_id
      WHERE pending.teacher_id = ?
      ORDER BY students.last_name COLLATE NOCASE,
               students.first_name COLLATE NOCASE
    ''', [teacherId]);
  }

  Future<void> markTeacherEnrollmentSyncError({
    required String lectureId,
    required String studentId,
    required String error,
  }) async {
    final db = await database;
    await db.update(
      'pending_teacher_enrollments',
      {'last_error': error},
      where: 'lecture_id = ? AND student_id = ?',
      whereArgs: [lectureId, studentId],
    );
  }

  Future<void> acknowledgeTeacherEnrollment({
    required String lectureId,
    required String pendingStudentId,
    required Student canonicalStudent,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'students',
        where: 'id = ?',
        whereArgs: [canonicalStudent.id],
        limit: 1,
      );
      final pendingStudent = await txn.query(
        'students',
        columns: [
          'biometric_enrollment_captured_at',
          'biometric_enrollment_method',
        ],
        where: 'id = ?',
        whereArgs: [pendingStudentId],
        limit: 1,
      );
      final canonicalRow = canonicalStudent.toMap();
      if (existing.isNotEmpty) {
        canonicalRow['biometric_enrollment_captured_at'] ??=
            existing.single['biometric_enrollment_captured_at'];
        canonicalRow['biometric_enrollment_method'] ??=
            existing.single['biometric_enrollment_method'];
      }
      if (pendingStudent.isNotEmpty) {
        canonicalRow['biometric_enrollment_captured_at'] ??=
            pendingStudent.single['biometric_enrollment_captured_at'];
        canonicalRow['biometric_enrollment_method'] ??=
            pendingStudent.single['biometric_enrollment_method'];
      }
      if (canonicalStudent.id == pendingStudentId || existing.isEmpty) {
        await txn.update(
          'students',
          canonicalRow,
          where: 'id = ?',
          whereArgs: [pendingStudentId],
        );
      } else {
        await txn.delete(
          'students',
          where: 'id = ?',
          whereArgs: [pendingStudentId],
        );
        await txn.update(
          'students',
          canonicalRow,
          where: 'id = ?',
          whereArgs: [canonicalStudent.id],
        );
      }

      final pendingEnrollments = await txn.query(
        'enrollments',
        where: 'student_id = ?',
        whereArgs: [pendingStudentId],
      );
      for (final enrollment in pendingEnrollments) {
        await txn.insert(
          'enrollments',
          {
            'lecture_id': enrollment['lecture_id'],
            'student_id': canonicalStudent.id,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await txn.delete(
        'enrollments',
        where: 'student_id = ?',
        whereArgs: [pendingStudentId],
      );
      await txn.update(
        'attendance_records',
        {'student_id': canonicalStudent.id},
        where: 'student_id = ?',
        whereArgs: [pendingStudentId],
      );
      await txn.insert(
        'enrollments',
        {'lecture_id': lectureId, 'student_id': canonicalStudent.id},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'pending_teacher_enrollments',
        where: 'lecture_id = ? AND student_id = ?',
        whereArgs: [lectureId, pendingStudentId],
      );
    });
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
            grade_level INTEGER,
            homeroom TEXT,
            biometric_enrollment_captured_at TEXT,
            biometric_enrollment_method TEXT
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
            academic_term TEXT NOT NULL DEFAULT 'TBD',
            late_grace_minutes INTEGER NOT NULL DEFAULT 10
          );
          ''');

          await db.execute('''
          CREATE TABLE pending_lecture_timetable_updates (
            lecture_id TEXT PRIMARY KEY,
            teacher_id TEXT NOT NULL,
            room_number TEXT NOT NULL,
            period_number INTEGER NOT NULL,
            academic_term TEXT NOT NULL,
            late_grace_minutes INTEGER NOT NULL
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
          CREATE TABLE pending_teacher_enrollments (
            lecture_id TEXT NOT NULL,
            student_id TEXT NOT NULL,
            teacher_id TEXT NOT NULL,
            last_error TEXT,
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
            override_by TEXT,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            device_recorded_at TEXT NOT NULL,
            row_version INTEGER NOT NULL DEFAULT 1,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_retry_at TEXT,
            UNIQUE(session_id, student_id)
          );
          ''');

          await db.execute('''
          CREATE TABLE school_settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            excused_counts_as_attended INTEGER NOT NULL DEFAULT 0
          );
          ''');
          await _createAdminCacheTables(db);
          await _createUserRoleCacheTable(db);
          await db.insert('school_settings', {
            'id': 1,
            'excused_counts_as_attended': 0,
          });

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
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE attendance_records ADD COLUMN override_by TEXT;',
            );
            await db.execute('''
              CREATE TABLE school_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                excused_counts_as_attended INTEGER NOT NULL DEFAULT 0
              )
            ''');
            await db.insert(
              'school_settings',
              {'id': 1, 'excused_counts_as_attended': 0},
            );
          }
          if (oldVersion < 5) {
            final lectureColumns =
                await db.rawQuery('PRAGMA table_info(lectures);');
            if (lectureColumns.isEmpty) {
              await db.execute('''
                CREATE TABLE lectures (
                  id TEXT PRIMARY KEY,
                  course_code TEXT NOT NULL,
                  title TEXT NOT NULL,
                  teacher_id TEXT NOT NULL,
                  teacher_name TEXT NOT NULL,
                  room_number TEXT NOT NULL,
                  period_number INTEGER NOT NULL,
                  academic_term TEXT NOT NULL DEFAULT 'TBD',
                  late_grace_minutes INTEGER NOT NULL DEFAULT 10
                );
              ''');
            } else {
              await db.execute(
                "ALTER TABLE lectures ADD COLUMN academic_term TEXT NOT NULL DEFAULT 'TBD';",
              );
            }
          }
          if (oldVersion < 10) {
            final studentColumns = await db.rawQuery(
              'PRAGMA table_info(students);',
            );
            if (studentColumns.isEmpty) {
              // Very old or partially provisioned databases may not have the
              // roster table yet. Create it with the v10 nullable shape.
              await db.execute('''
                CREATE TABLE students (
                  id TEXT PRIMARY KEY,
                  student_code TEXT NOT NULL UNIQUE,
                  first_name TEXT NOT NULL,
                  last_name TEXT NOT NULL,
                  grade_level INTEGER,
                  homeroom TEXT,
                  biometric_enrollment_captured_at TEXT,
                  biometric_enrollment_method TEXT
                );
              ''');
            } else {
              // SQLite cannot drop the legacy NOT NULL constraints in place, so
              // rebuild the table and add the biometric capture columns.
              await db.execute('ALTER TABLE students RENAME TO students_v9;');
              await db.execute('''
                CREATE TABLE students (
                  id TEXT PRIMARY KEY,
                  student_code TEXT NOT NULL UNIQUE,
                  first_name TEXT NOT NULL,
                  last_name TEXT NOT NULL,
                  grade_level INTEGER,
                  homeroom TEXT,
                  biometric_enrollment_captured_at TEXT,
                  biometric_enrollment_method TEXT
                );
              ''');
              await db.execute('''
                INSERT INTO students (
                  id, student_code, first_name, last_name, grade_level, homeroom
                )
                SELECT id, student_code, first_name, last_name, grade_level, homeroom
                FROM students_v9;
              ''');
              await db.execute('DROP TABLE students_v9;');
            }
            await db.execute('''
              CREATE TABLE IF NOT EXISTS pending_teacher_enrollments (
                lecture_id TEXT NOT NULL,
                student_id TEXT NOT NULL,
                teacher_id TEXT NOT NULL,
                last_error TEXT,
                PRIMARY KEY (lecture_id, student_id)
              );
            ''');
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_students_alpha ON students(last_name COLLATE NOCASE, first_name COLLATE NOCASE);',
            );
          }
          if (oldVersion < 6) {
            await db.execute('''
              CREATE TABLE pending_lecture_timetable_updates (
                lecture_id TEXT PRIMARY KEY,
                teacher_id TEXT NOT NULL,
                room_number TEXT NOT NULL,
                period_number INTEGER NOT NULL,
                academic_term TEXT NOT NULL,
                late_grace_minutes INTEGER NOT NULL
              );
            ''');
          }
          if (oldVersion < 7) {
            await _createAdminCacheTables(db);
          }
          if (oldVersion < 8) {
            await _createUserRoleCacheTable(db);
          }
          if (oldVersion < 9) {
            final cacheColumns = await db.rawQuery(
              'PRAGMA table_info(admin_students_cache);',
            );
            if (cacheColumns.isNotEmpty &&
                !cacheColumns.any((column) => column['name'] == 'profile_id')) {
              await db.execute(
                'ALTER TABLE admin_students_cache ADD COLUMN profile_id TEXT;',
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _createUserRoleCacheTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE user_profile_role_cache (
        user_id TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createAdminCacheTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE admin_profiles_cache (
        id TEXT PRIMARY KEY,
        full_name TEXT NOT NULL,
        email TEXT NOT NULL,
        role TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE admin_students_cache (
        id TEXT PRIMARY KEY,
        student_code TEXT NOT NULL UNIQUE,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL,
        grade_level INTEGER NOT NULL,
        homeroom TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        profile_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE admin_enrollments_cache (
        lecture_id TEXT NOT NULL,
        student_id TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (lecture_id, student_id)
      )
    ''');
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
        where: '''
          lecture_id = ?
          AND student_id NOT IN (
            SELECT student_id FROM pending_teacher_enrollments
            WHERE lecture_id = ?
          )
        ''',
        whereArgs: [lecture.id, lecture.id],
      );
      final batch = txn.batch();
      for (final student in students) {
        final cachedCapture = await txn.query(
          'students',
          columns: [
            'biometric_enrollment_captured_at',
            'biometric_enrollment_method',
          ],
          where: 'id = ?',
          whereArgs: [student.id],
          limit: 1,
        );
        final studentMap = student.toMap();
        if (cachedCapture.isNotEmpty) {
          studentMap['biometric_enrollment_captured_at'] ??=
              cachedCapture.single['biometric_enrollment_captured_at'];
          studentMap['biometric_enrollment_method'] ??=
              cachedCapture.single['biometric_enrollment_method'];
        }
        batch.insert(
          'students',
          studentMap,
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

  Future<void> cacheAdminProfiles(List<Map<String, dynamic>> profiles) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('admin_profiles_cache');
      final batch = txn.batch();
      for (final profile in profiles) {
        batch.insert(
          'admin_profiles_cache',
          {
            'id': profile['id'],
            'full_name': profile['full_name'],
            'email': profile['email'],
            'role': profile['role'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, Object?>>> getCachedAdminProfiles() async {
    final db = await database;
    return db.query('admin_profiles_cache',
        orderBy: 'full_name COLLATE NOCASE');
  }

  Future<void> cacheUserProfileRole(String userId, String? role) async {
    final db = await database;
    if (role == null) {
      await db.delete(
        'user_profile_role_cache',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      return;
    }
    await db.insert(
      'user_profile_role_cache',
      {
        'user_id': userId,
        'role': role,
        'cached_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getCachedUserProfileRole(String userId) async {
    final db = await database;
    final rows = await db.query(
      'user_profile_role_cache',
      columns: ['role'],
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['role'] as String;
  }

  Future<void> cacheAdminStudents(List<Map<String, dynamic>> students) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('admin_students_cache');
      final batch = txn.batch();
      for (final student in students) {
        batch.insert(
          'admin_students_cache',
          _adminStudentSqliteMap(student),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      for (final student in students) {
        await _cacheRosterStudent(txn, student);
      }
    });
  }

  Future<List<Map<String, Object?>>> getCachedAdminStudents() async {
    final db = await database;
    return db.query(
      'admin_students_cache',
      orderBy: 'last_name COLLATE NOCASE, first_name COLLATE NOCASE',
    );
  }

  Future<void> cacheAdminStudent(Map<String, dynamic> student) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'admin_students_cache',
        _adminStudentSqliteMap(student),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _cacheRosterStudent(txn, student);
    });
  }

  Future<void> _cacheRosterStudent(
    DatabaseExecutor db,
    Map<String, dynamic> student,
  ) async {
    await db.insert(
      'students',
      {
        'id': student['id'],
        'student_code': student['student_code'],
        'first_name': student['first_name'],
        'last_name': student['last_name'],
        'grade_level': student['grade_level'],
        'homeroom': student['homeroom'],
        'biometric_enrollment_captured_at':
            student['biometric_enrollment_captured_at'],
        'biometric_enrollment_method': student['biometric_enrollment_method'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (student['active'] != true && student['active'] != 1) {
      await db.delete(
        'enrollments',
        where: 'student_id = ?',
        whereArgs: [student['id']],
      );
    }
  }

  Map<String, Object?> _adminStudentSqliteMap(Map<String, dynamic> student) => {
        'id': student['id'],
        'student_code': student['student_code'],
        'first_name': student['first_name'],
        'last_name': student['last_name'],
        'grade_level': student['grade_level'],
        'homeroom': student['homeroom'],
        'active': student['active'] == true || student['active'] == 1 ? 1 : 0,
        'profile_id': student['profile_id'],
      };

  Future<void> cacheAdminEnrollments(
    String lectureId,
    List<Map<String, dynamic>> enrollments,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'admin_enrollments_cache',
        where: 'lecture_id = ?',
        whereArgs: [lectureId],
      );
      final batch = txn.batch();
      for (final enrollment in enrollments) {
        batch.insert(
          'admin_enrollments_cache',
          {
            'lecture_id': lectureId,
            'student_id': enrollment['student_id'],
            'active': enrollment['active'] == true || enrollment['active'] == 1
                ? 1
                : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, Object?>>> getCachedAdminEnrollments(
      String lectureId) async {
    final db = await database;
    return db.query(
      'admin_enrollments_cache',
      where: 'lecture_id = ?',
      whereArgs: [lectureId],
      orderBy: 'student_id',
    );
  }

  Future<void> cacheAdminEnrollment({
    required String lectureId,
    required String studentId,
    required bool active,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'admin_enrollments_cache',
        {
          'lecture_id': lectureId,
          'student_id': studentId,
          'active': active ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (active) {
        final studentRows = await txn.query(
          'admin_students_cache',
          where: 'id = ? AND active = 1',
          whereArgs: [studentId],
          limit: 1,
        );
        if (studentRows.isEmpty) {
          throw StateError(
            'Cannot cache enrollment for a student missing from the local cache.',
          );
        }
        final student = studentRows.single;
        await txn.insert(
          'students',
          {
            'id': student['id'],
            'student_code': student['student_code'],
            'first_name': student['first_name'],
            'last_name': student['last_name'],
            'grade_level': student['grade_level'],
            'homeroom': student['homeroom'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.insert(
          'enrollments',
          {'lecture_id': lectureId, 'student_id': studentId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        await txn.delete(
          'enrollments',
          where: 'lecture_id = ? AND student_id = ?',
          whereArgs: [lectureId, studentId],
        );
      }
    });
  }

  Future<void> cachePendingLectureTimetableEdit(Lecture lecture) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'lectures',
        lecture.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'pending_lecture_timetable_updates',
        {
          'lecture_id': lecture.id,
          'teacher_id': lecture.teacherId,
          'room_number': lecture.roomNumber,
          'period_number': lecture.periodNumber,
          'academic_term': lecture.academicTerm,
          'late_grace_minutes': lecture.lateGraceMinutes,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<Lecture>> getPendingLectureTimetableEdits(
      String teacherId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT lectures.*
      FROM lectures
      INNER JOIN pending_lecture_timetable_updates AS pending
        ON pending.lecture_id = lectures.id
      WHERE pending.teacher_id = ?
      ORDER BY lectures.period_number
    ''', [teacherId]);
    return rows.map(Lecture.fromMap).toList();
  }

  Future<int> getPendingLectureTimetableEditCount(String teacherId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM pending_lecture_timetable_updates
      WHERE teacher_id = ?
    ''', [teacherId]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> clearPendingLectureTimetableEdit(String lectureId) async {
    final db = await database;
    await db.delete(
      'pending_lecture_timetable_updates',
      where: 'lecture_id = ?',
      whereArgs: [lectureId],
    );
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
    ''', [lectureId]);
    return sortStudents(rows.map(Student.fromMap).toList());
  }

  Future<SchoolSettings> getSchoolSettings() async {
    final db = await database;
    final rows = await db.query(
      'school_settings',
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return const SchoolSettings();
    return SchoolSettings.fromMap(rows.first);
  }

  Future<void> cacheSchoolSettings(SchoolSettings settings) async {
    final db = await database;
    await db.insert(
      'school_settings',
      settings.toSqliteMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getLectureHistory(String lectureId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        s.id,
        s.session_date,
        s.started_at,
        s.ended_at,
        s.enrolled_count,
        COUNT(r.id) AS recorded_count,
        SUM(CASE WHEN r.status IN ('present', 'late') THEN 1 ELSE 0 END)
          AS checked_in_count,
        SUM(CASE WHEN r.status = 'absent' THEN 1 ELSE 0 END) AS absent_count
      FROM attendance_sessions AS s
      LEFT JOIN attendance_records AS r ON r.session_id = s.id
      WHERE s.lecture_id = ? AND s.ended_at IS NOT NULL
      GROUP BY s.id
      ORDER BY s.session_date DESC, s.started_at DESC
    ''', [lectureId]);
  }

  Future<List<Map<String, Object?>>> getSessionHistoryRecords(
      String sessionId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT r.*, s.first_name, s.last_name, s.student_code
      FROM attendance_records AS r
      LEFT JOIN students AS s ON s.id = r.student_id
      WHERE r.session_id = ?
      ORDER BY s.last_name COLLATE NOCASE, s.first_name COLLATE NOCASE
    ''', [sessionId]);
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
    AttendanceSession session, {
    bool rejectTeacherDateConflict = false,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      if (rejectTeacherDateConflict) {
        final conflictingSessions = await txn.query(
          'attendance_sessions',
          where: 'teacher_id = ? AND session_date = ? AND ended_at IS NULL',
          whereArgs: [session.teacherId, session.sessionDate],
        );
        if (conflictingSessions.any(
          (row) => row['lecture_id'] != session.lectureId,
        )) {
          throw StateError(
            'Another course already has an active session today. End it before starting this course.',
          );
        }
      }

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

  Future<List<AttendanceSession>> getSessionsForTeacherOnDate(
    String teacherId,
    String sessionDate,
  ) async {
    final db = await database;
    final rows = await db.query(
      'attendance_sessions',
      where: 'teacher_id = ? AND session_date = ?',
      whereArgs: [teacherId, sessionDate],
      orderBy: 'started_at DESC',
    );
    return rows.map(AttendanceSession.fromMap).toList();
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
      '''
      SELECT
        (SELECT COUNT(*) FROM attendance_records WHERE sync_status != ?) +
        (SELECT COUNT(*) FROM pending_teacher_enrollments) AS cnt
      ''',
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
            AND submitted_to_cloud_synced = 0) +
        (SELECT COUNT(*) FROM pending_teacher_enrollments) AS cnt
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

  Future<int> markSessionSubmissionSynced(
    String sessionId,
    String submittedAt,
  ) async {
    final db = await database;
    return db.update(
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
