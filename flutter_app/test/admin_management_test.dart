import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late LocalDatabaseService database;
  late LectureSessionNotifier notifier;
  late List<String> requestPaths;
  late SupabaseClient client;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    requestPaths = [];
    final student = {
      'id': 'student-1',
      'student_code': 'STU-1',
      'first_name': 'Amina',
      'last_name': 'Bello',
      'grade_level': 10,
      'homeroom': '10A',
      'active': true,
      'profile_id': null,
    };
    client = SupabaseClient(
      'https://lectureguard.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        requestPaths.add(path);
        if (path.endsWith('/profiles') && request.method == 'GET') {
          return _json([
            {
              'id': 'profile-1',
              'full_name': 'Teacher One',
              'email': 'teacher@example.test',
              'role': 'teacher',
            },
          ], request);
        }
        if (path.endsWith('/rpc/admin_set_user_role')) {
          expect(jsonDecode(request.body), {
            'p_email': 'teacher@example.test',
            'p_role': 'admin',
          });
          return _json('profile-1', request);
        }
        if (path.endsWith('/students') && request.method == 'POST') {
          return _json(student, request);
        }
        if (path.endsWith('/students') && request.method == 'PATCH') {
          final values = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({...student, ...values}, request);
        }
        if (path.endsWith('/enrollments') && request.method == 'POST') {
          return _json({
            'lecture_id': 'lecture-1',
            'student_id': 'student-1',
            'active': true,
          }, request);
        }
        if (path.endsWith('/enrollments') && request.method == 'PATCH') {
          return _json(
            {
              'lecture_id': 'lecture-1',
              'student_id': 'student-1',
              'active': false,
            },
            request,
          );
        }
        return _json([], request);
      }),
    );
    notifier = LectureSessionNotifier(
      database,
      BiometricService(),
      _OfflineSyncEngine(database),
    );
    await notifier.initialization;
  });

  tearDown(() async {
    notifier.dispose();
    await database.close();
    await client.dispose();
  });

  test('profiles and role changes are cached after the admin RPC succeeds',
      () async {
    final profiles = await notifier.loadAdminProfiles(client: client);
    expect(profiles.single['role'], 'teacher');

    await notifier.setAdminProfileRole(
      profileId: 'profile-1',
      email: 'teacher@example.test',
      role: UserRole.admin,
      client: client,
    );

    expect(
      (await database.getCachedAdminProfiles()).single['role'],
      'admin',
    );
    expect(await database.getCachedUserProfileRole('profile-1'), 'admin');
    expect(
      requestPaths.any((path) => path.endsWith('/rpc/admin_set_user_role')),
      isTrue,
    );
  });

  test('student create/update and enrollment changes persist to SQLite cache',
      () async {
    final student = await notifier.createAdminStudent(
      studentCode: ' STU-1 ',
      firstName: ' Amina ',
      lastName: ' Bello ',
      gradeLevel: 10,
      homeroom: ' 10A ',
      client: client,
    );
    expect(student['student_code'], 'STU-1');
    expect((await database.getCachedAdminStudents()).single['active'], 1);

    await notifier.setAdminEnrollment(
      lectureId: 'lecture-1',
      studentId: 'student-1',
      active: true,
      client: client,
    );
    expect(
      (await database.getCachedAdminEnrollments('lecture-1')).single['active'],
      1,
    );

    await notifier.setAdminEnrollment(
      lectureId: 'lecture-1',
      studentId: 'student-1',
      active: false,
      client: client,
    );
    expect(
      (await database.getCachedAdminEnrollments('lecture-1')).single['active'],
      0,
    );

    await notifier.updateAdminStudent(
      studentId: 'student-1',
      studentCode: 'STU-1',
      firstName: 'Amina',
      lastName: 'Bello',
      gradeLevel: 10,
      homeroom: '10A',
      active: false,
      client: client,
    );
    expect((await database.getCachedAdminStudents()).single['active'], 0);
    final enrollmentWrites =
        requestPaths.where((path) => path.endsWith('/enrollments')).length;
    await expectLater(
      notifier.setAdminEnrollment(
        lectureId: 'lecture-1',
        studentId: 'student-1',
        active: true,
        client: client,
      ),
      throwsStateError,
    );
    expect(
      requestPaths.where((path) => path.endsWith('/enrollments')).length,
      enrollmentWrites,
    );
  });

  test('student validation rejects a grade outside the school range', () async {
    await expectLater(
      notifier.createAdminStudent(
        studentCode: 'STU-2',
        firstName: 'Kofi',
        lastName: 'Mensah',
        gradeLevel: 13,
        homeroom: '10A',
        client: client,
      ),
      throwsArgumentError,
    );
  });

  test('student login linking updates the cached profile id', () async {
    await notifier.createAdminStudent(
      studentCode: 'STU-1',
      firstName: 'Amina',
      lastName: 'Bello',
      gradeLevel: 10,
      homeroom: '10A',
      client: client,
    );

    final linked = await notifier.setAdminStudentProfile(
      studentId: 'student-1',
      profileId: ' profile-student ',
      client: client,
    );
    expect(linked['profile_id'], 'profile-student');
    expect(
      (await database.getCachedAdminStudents()).single['profile_id'],
      'profile-student',
    );

    final unlinked = await notifier.setAdminStudentProfile(
      studentId: 'student-1',
      client: client,
    );
    expect(unlinked['profile_id'], isNull);
    expect(
      (await database.getCachedAdminStudents()).single['profile_id'],
      isNull,
    );
  });
}

http.Response _json(Object body, [http.BaseRequest? request]) => http.Response(
      jsonEncode(body),
      200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-range': '0-0/1',
      },
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
