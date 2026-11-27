import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('the local database opens in WAL journal mode', () async {
    // WAL is not available for :memory: databases, so use a real file.
    final directory = await Directory.systemTemp.createTemp('lectureguard_wal');
    final service = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: p.join(directory.path, 'lectureguard.db'),
    );
    addTearDown(() async {
      await service.close();
      await directory.delete(recursive: true);
    });

    final db = await service.database;
    final rows = await db.rawQuery('PRAGMA journal_mode;');
    expect(rows, hasLength(1));
    expect(
      (rows.single.values.single as String).toLowerCase(),
      'wal',
      reason: 'offline-first writes rely on WAL for concurrent reads',
    );

    final settings = await service.getSchoolSettings();
    expect(settings.excusedCountsAsAttended, isFalse);
  });

  test('cached lectures retain their academic term', () async {
    final service = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(service.close);

    const lecture = Lecture(
      id: 'lecture-1',
      courseCode: 'BIO-101',
      title: 'Biology',
      teacherId: 'teacher-1',
      teacherName: 'Teacher',
      roomNumber: 'A1',
      periodNumber: 2,
      academicTerm: '2026-T2',
    );
    await service.cacheLectures([lecture]);

    final cached = await service.getCachedLecture(lecture.id);
    expect(cached?.academicTerm, '2026-T2');
  });
}
