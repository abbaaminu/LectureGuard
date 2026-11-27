import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/session_ids.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const teacherId = 'teacher-1';
  const lecture = Lecture(
    id: 'lecture-1',
    courseCode: 'BIO-101',
    title: 'Biology',
    teacherId: teacherId,
    teacherName: 'Teacher',
    roomNumber: 'A1',
    periodNumber: 1,
    academicTerm: '2026-T1',
  );
  const students = [
    Student(
      id: 'student-1',
      studentCode: 'STU-1',
      firstName: 'Amina',
      lastName: 'Bello',
      gradeLevel: 10,
      homeroom: '10A',
    ),
  ];

  late LocalDatabaseService database;
  late _OfflineSyncEngine sync;
  late LectureSessionNotifier notifier;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    await database.cacheLectureRoster(lecture, students);
    sync = _OfflineSyncEngine(database);
    notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      sync,
      currentUserId: () => teacherId,
    );
    await notifier.initialization;
  });
  tearDown(() async {
    notifier.dispose();
    sync.dispose();
    await database.close();
  });

  test('local ownership validation rejects a course assigned to another user',
      () async {
    final otherTeacherLecture = lecture.copyWith().toMap()
      ..['teacher_id'] = 'teacher-2';
    await database.cacheLectures([Lecture.fromMap(otherTeacherLecture)]);

    final error = await notifier.validateLectureAssignmentLocally(lecture);

    expect(error, contains('cached course is assigned to another lecturer'));
  });

  test('placeholder timetable blocks local session validation', () async {
    final unconfigured = lecture.copyWith(roomNumber: 'TBD');
    await database.cacheLectureRoster(unconfigured, students);
    await notifier.selectLecture(unconfigured, students);

    expect(
      await notifier.validateStartSessionLocally(),
      contains('Configure this course timetable on your device'),
    );
  });

  test('an active local session for another course blocks starting', () async {
    await notifier.selectLecture(lecture, students);
    final now = DateTime.now();
    await database.upsertSession(
      AttendanceSession(
        id: 'conflicting-session',
        lectureId: 'lecture-2',
        teacherId: teacherId,
        deviceId: 'device-1',
        sessionDate: localSessionDate(now),
        startedAt: now,
        enrolledCount: 1,
      ),
    );

    expect(
      await notifier.validateStartSessionLocally(),
      contains('Another course already has an active session today'),
    );
    await expectLater(
      notifier.startPassModeSession(lecture: lecture, students: students),
      throwsA(isA<StateError>()),
    );
  });

  test('an active session conflict also blocks Pass Mode launch', () async {
    await notifier.selectLecture(lecture, students);
    await notifier.startPassModeSession(lecture: lecture, students: students);
    final now = DateTime.now();
    await database.upsertSession(
      AttendanceSession(
        id: 'conflicting-session',
        lectureId: 'lecture-2',
        teacherId: teacherId,
        deviceId: 'device-2',
        sessionDate: localSessionDate(now),
        startedAt: now,
        enrolledCount: 1,
      ),
    );

    expect(
      await notifier.validatePassModeLaunchLocally(),
      contains('Another course already has an active session today'),
    );
    await expectLater(notifier.lockPassMode(), throwsA(isA<StateError>()));
  });

  test('valid assigned course passes local checks without a network request',
      () async {
    await notifier.selectLecture(lecture, students);

    expect(await notifier.validateStartSessionLocally(), isNull);
  });

  test('timetable edits are cached locally and queued while offline', () async {
    final updated = await notifier.updateTeacherLectureTimetable(
      lecture: lecture,
      roomNumber: 'B2',
      periodNumber: 3,
      academicTerm: '2026-T2',
      lateGraceMinutes: 12,
    );

    expect(updated.roomNumber, 'B2');
    expect(
        (await database.getCachedLecture(lecture.id))?.academicTerm, '2026-T2');
    expect(
      (await database.getPendingLectureTimetableEdits(teacherId)).single.id,
      lecture.id,
    );
    expect(await notifier.validateLectureLocally(updated), isNull);
  });

  test('admin course assignment persists returned assignment and caches it',
      () async {
    final row = {
      'id': 'new-lecture',
      'course_code': 'CHEM-101',
      'title': 'Chemistry',
      'teacher_id': teacherId,
      'teacher_name': 'Teacher',
      'room_number': 'TBD',
      'period_number': 1,
      'academic_term': '2026-T2',
      'late_grace_minutes': 10,
    };
    final client = SupabaseClient(
      'https://lectureguard.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body), {
          'course_code': 'CHEM-101',
          'title': 'Chemistry',
          'teacher_id': teacherId,
          'room_number': 'TBD',
          'period_number': 1,
          'academic_term': '2026-T2',
        });
        return httpJson(row, request);
      }),
    );

    final assigned = await notifier.createLectureAssignment(
      courseCode: ' CHEM-101 ',
      title: ' Chemistry ',
      teacherId: teacherId,
      roomNumber: 'TBD',
      periodNumber: 1,
      academicTerm: '2026-T2',
      client: client,
    );

    expect(assigned.id, 'new-lecture');
    expect(
        (await database.getCachedLecture(assigned.id))?.teacherId, teacherId);
  });
}

http.Response httpJson(Object body, [http.BaseRequest? request]) =>
    http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );

class _OfflineSyncEngine extends SyncEngineService {
  _OfflineSyncEngine(LocalDatabaseService database)
      : super(
          database,
          SupabaseClient(
            'https://lectureguard.test',
            'test-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        );

  @override
  Future<NetworkTransport> currentTransport() async => NetworkTransport.offline;

  @override
  void startAutoSyncListener({
    void Function(NetworkTransport transport)? onConnectivityChanged,
    void Function(SyncProgress progress)? onBatchProgress,
    void Function(SyncResult result)? onSyncComplete,
  }) {}
}
