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
        if (path.endsWith('/functions/v1/admin-create-user')) {
          final values = jsonDecode(request.body) as Map<String, dynamic>;
          expect(values, {
            'email': 'new.teacher@example.test',
            'password': 'LongPassphrase2026!',
            'role': 'teacher',
            'full_name': 'New Teacher',
            'department': 'Science',
          });
          return _json({
            'id': 'profile-new',
            'full_name': 'New Teacher',
            'email': 'new.teacher@example.test',
            'role': 'teacher',
            'department': 'Science',
          }, request);
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

  test('staff account creation calls the Edge Function and caches the profile',
      () async {
    final profile = await notifier.createStaffLogin(
      email: 'new.teacher@example.test',
      password: 'LongPassphrase2026!',
      role: UserRole.teacher,
      fullName: 'New Teacher',
      department: 'Science',
      client: client,
    );

    expect(profile['id'], 'profile-new');
    expect(profile['role'], 'teacher');
    expect((await database.getCachedAdminProfiles()).single['email'],
        'new.teacher@example.test');
    expect(
      requestPaths
          .any((path) => path.endsWith('/functions/v1/admin-create-user')),
      isTrue,
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
