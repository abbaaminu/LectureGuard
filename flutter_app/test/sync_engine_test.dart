import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';

void main() {
  late LocalDatabaseService database;
  final engines = <SyncEngineService>[];
  final clients = <_FakeSupabaseHttpClient>[];

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
  });

  tearDown(() async {
    for (final engine in engines) {
      engine.dispose();
    }
    engines.clear();
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await database.close();
  });

  SyncEngineService engine0(
    _FakeSupabaseHttpClient client, {
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
    Future<bool> Function()? reachabilityCheck,
    String? Function()? currentUserId,
  }) {
    final engine = SyncEngineService(
      database,
      SupabaseClient(
        'https://lectureguard.test',
        'test-key',
        httpClient: client,
      ),
      connectivityChanges: connectivityChanges,
      connectivityCheck:
          connectivityCheck ?? () async => [ConnectivityResult.wifi],
      reachabilityCheck: reachabilityCheck ?? () async => true,
      retryDelay: (_) => Duration.zero,
      currentUserId: currentUserId,
    );
    engines.add(engine);
    return engine;
  }

  _FakeSupabaseHttpClient client0(
    Future<http.Response> Function(http.BaseRequest request, String body)
        handle,
  ) {
    final client = _FakeSupabaseHttpClient(handle);
    clients.add(client);
    return client;
  }

  AttendanceRecord record0(AttendanceSession session, int index) =>
      AttendanceRecord(
        id: 'record-${session.id}-$index',
        sessionId: session.id,
        lectureId: session.lectureId,
        studentId: 'student-$index',
        status: AttendanceStatus.present,
        checkedInAt: DateTime(2026, 11, 19, 9, 10),
        biometricVerified: true,
        biometricMethod: 'face',
        deviceRecordedAt:
            DateTime(2026, 11, 19, 9, 10).add(Duration(seconds: index)),
      );

  Future<void> addRecords(AttendanceSession session, int count) async {
    for (var index = 0; index < count; index++) {
      await database.upsertAttendanceRecord(record0(session, index));
    }
  }

  AttendanceSession session0(
    String id, {
    required int enrolledCount,
  }) =>
      AttendanceSession(
        id: id,
        lectureId: 'lecture-$id',
        teacherId: 'teacher-1',
        deviceId: 'device-1',
        sessionDate: '2026-11-19',
        startedAt: DateTime(2026, 11, 19, 9),
        enrolledCount: enrolledCount,
      );

  test('continues after one records batch exhausts retries', () async {
    var failedBatchAttempts = 0;
    final client = client0((request, body) async {
      if (request.url.path.endsWith('/attendance_sessions')) {
        return http.Response('', 201);
      }
      final records = jsonDecode(body) as List<dynamic>;
      if (records.length == SyncEngineService.batchChunkSize) {
        failedBatchAttempts++;
        return http.Response('{"message":"temporary failure"}', 500);
      }
      return http.Response('', 201);
    });
    final session = session0('session-partial', enrolledCount: 52);
    await database.createSessionIfAbsent(session);
    await addRecords(session, 52);

    final result = await engine0(client).syncPendingRecords();

    final rows = await (await database.database).query('attendance_records');
    final failedRows =
        rows.where((row) => row['sync_status'] == SyncStatus.failed.name);
    final syncedRows =
        rows.where((row) => row['sync_status'] == SyncStatus.synced.name);
    final recordRequests = client.requests
        .where((request) => request.url.path.endsWith('/attendance_records'))
        .toList();

    expect(result.success, isFalse);
    expect(failedBatchAttempts, 3);
    expect(failedRows, hasLength(50));
    expect(syncedRows, hasLength(2));
    expect(failedRows.every((row) => row['attempt_count'] == 1), isTrue);
    expect(failedRows.every((row) => row['last_error'] != null), isTrue);
    expect(failedRows.every((row) => row['row_version'] == 2), isTrue);
    expect(syncedRows.every((row) => row['row_version'] == 2), isTrue);
    expect(recordRequests, hasLength(4));
    expect(
      recordRequests.last.url.queryParameters['on_conflict'],
      'id',
    );
    final uploadedRecord =
        jsonDecode(recordRequests.first.body).first as Map<String, dynamic>;
    expect(uploadedRecord['id'], startsWith('record-session-partial-'));
  });

  test('an edit during upload remains pending after the stale ack', () async {
    final uploadStarted = Completer<void>();
    final uploadResponse = Completer<http.Response>();
    final client = client0((request, body) async {
      if (request.url.path.endsWith('/attendance_records')) {
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        return uploadResponse.future;
      }
      return http.Response('', 201);
    });
    final session = session0('session-edit', enrolledCount: 1);
    await database.createSessionIfAbsent(session);
    final original = record0(session, 1);
    await database.upsertAttendanceRecord(original);

    final syncFuture = engine0(client).syncPendingRecords();
    await uploadStarted.future.timeout(const Duration(seconds: 5));

    final current = (await database.getSessionRecords(session.id)).single;
    await database.upsertAttendanceRecord(
      current.copyWith(
        status: AttendanceStatus.late,
        deviceRecordedAt: current.deviceRecordedAt.add(
          const Duration(minutes: 1),
        ),
      ),
    );
    uploadResponse.complete(http.Response('', 201));
    final result = await syncFuture;

    final record = (await database.getSessionRecords(session.id)).single;
    expect(result.success, isFalse);
    expect(record.status, AttendanceStatus.late);
    expect(record.rowVersion, 2);
    expect(record.syncStatus, SyncStatus.pending);
  });

  test('connectivity change from offline to online starts a sync', () async {
    final connectivity = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(connectivity.close);
    var currentConnectivity = <ConnectivityResult>[];
    final firstResult = Completer<SyncResult>();
    final onlineResult = Completer<SyncResult>();
    final client = client0((request, body) async {
      if (request.method == 'PATCH' && request.url.path.endsWith('/lectures')) {
        return http.Response(
          jsonEncode({'id': 'lecture-pending'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 201);
    });
    final session = session0('session-transition', enrolledCount: 1);
    await database.createSessionIfAbsent(session);
    await database.upsertAttendanceRecord(record0(session, 1));
    await database.cachePendingLectureTimetableEdit(
      const Lecture(
        id: 'lecture-pending',
        courseCode: 'BIO-1',
        title: 'Biology',
        teacherId: 'teacher-1',
        teacherName: 'Teacher',
        roomNumber: 'R2',
        periodNumber: 2,
        academicTerm: '2026-T2',
      ),
    );
    final engine = engine0(
      client,
      connectivityChanges: connectivity.stream,
      connectivityCheck: () async => currentConnectivity,
      currentUserId: () => 'teacher-1',
    );

    engine.startAutoSyncListener(
      onSyncComplete: (result) {
        if (!firstResult.isCompleted) {
          firstResult.complete(result);
        } else if (result.success && !onlineResult.isCompleted) {
          onlineResult.complete(result);
        }
      },
    );
    expect((await firstResult.future).success, isFalse);

    currentConnectivity = [ConnectivityResult.wifi];
    connectivity.add(currentConnectivity);
    expect(
        (await onlineResult.future.timeout(const Duration(seconds: 5))).success,
        isTrue);
    expect(
        await database.getPendingLectureTimetableEdits('teacher-1'), isEmpty);
    expect(
      client.requests.where((request) =>
          request.method == 'PATCH' && request.url.path.endsWith('/lectures')),
      hasLength(1),
    );
    expect(
      client.requests
          .where((request) => request.url.path.endsWith('/attendance_records'))
          .length,
      1,
    );
  });

  test('a poison session batch does not block later session batches', () async {
    final client = client0((request, body) async {
      if (request.url.path.endsWith('/attendance_sessions')) {
        final sessions = jsonDecode(body) as List<dynamic>;
        if (sessions.length == SyncEngineService.batchChunkSize) {
          return http.Response('{"message":"poison batch"}', 500);
        }
      }
      return http.Response('', 201);
    });
    final sessions = List.generate(
      SyncEngineService.batchChunkSize + 1,
      (index) => session0('session-poison-$index', enrolledCount: 1),
    );
    for (var index = 0; index < sessions.length; index++) {
      await database.createSessionIfAbsent(sessions[index]);
      await database.upsertAttendanceRecord(record0(sessions[index], index));
    }

    final result = await engine0(client).syncPendingRecords();

    final sessionRows =
        await (await database.database).query('attendance_sessions');
    final recordRows =
        await (await database.database).query('attendance_records');
    expect(result.success, isFalse);
    expect(
      sessionRows.where((row) => row['sync_status'] == SyncStatus.failed.name),
      hasLength(SyncEngineService.batchChunkSize),
    );
    expect(
      sessionRows.where((row) => row['sync_status'] == SyncStatus.synced.name),
      hasLength(1),
    );
    expect(
      recordRows.where((row) => row['sync_status'] == SyncStatus.synced.name),
      hasLength(1),
    );
    expect(
      client.requests
          .where((request) => request.url.path.endsWith('/attendance_records'))
          .length,
      1,
    );
  });

  test('submits an ended session after all of its records sync', () async {
    final client = client0((request, body) async {
      if (request.method == 'PATCH' &&
          request.url.path.endsWith('/attendance_sessions')) {
        return http.Response(
          jsonEncode({'id': 'session-submitted'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 201);
    });
    final session = session0('session-submitted', enrolledCount: 0);
    await database.createSessionIfAbsent(session);
    await database.endSession(session.id);

    final result = await engine0(client).syncPendingRecords();

    final row = (await (await database.database).query(
      'attendance_sessions',
      where: 'id = ?',
      whereArgs: [session.id],
    ))
        .single;
    final update = client.requests.firstWhere(
      (request) =>
          request.method == 'PATCH' &&
          request.url.path.endsWith('/attendance_sessions'),
    );
    expect(result.success, isTrue);
    expect(row['submitted_to_cloud_at'], isA<String>());
    expect(row['submitted_to_cloud_synced'], 1);
    expect(update.body, contains('submitted_to_cloud_at'));
  });

  test('filtered session submission update remains pending', () async {
    final client = client0((request, body) async {
      if (request.method == 'PATCH' &&
          request.url.path.endsWith('/attendance_sessions')) {
        return http.Response(
          jsonEncode({
            'code': 'PGRST116',
            'details': 'The result contains 0 rows',
            'hint': null,
            'message': 'JSON object requested, no rows returned',
          }),
          406,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 201);
    });
    final session = session0('session-filtered-submission', enrolledCount: 0);
    await database.createSessionIfAbsent(session);
    await database.endSession(session.id);

    final result = await engine0(client).syncPendingRecords();

    final row = (await (await database.database).query(
      'attendance_sessions',
      where: 'id = ?',
      whereArgs: [session.id],
    ))
        .single;
    expect(result.success, isFalse);
    expect(row['submitted_to_cloud_synced'], 0);
    expect(row['last_error'], contains('Session submission update failed'));
    expect(await database.getPendingSyncWorkCount(), greaterThan(0));
  });

  test('connectivity without Supabase reachability leaves rows queued',
      () async {
    final client = client0((request, body) async => http.Response('', 201));
    final session = session0('session-unreachable', enrolledCount: 1);
    await database.createSessionIfAbsent(session);
    await database.upsertAttendanceRecord(record0(session, 1));

    final result = await engine0(
      client,
      reachabilityCheck: () async => false,
    ).syncPendingRecords();

    expect(result.success, isFalse);
    expect(result.error, contains('unreachable'));
    expect(await database.getPendingSyncCount(), 1);
    expect(client.requests, isEmpty);
  });

  test('attendance record upserts send the deterministic id and conflict on it',
      () async {
    final client = client0((request, body) async => http.Response('', 201));
    final session = session0('session-identity', enrolledCount: 1);
    await database.createSessionIfAbsent(session);
    await database.upsertAttendanceRecord(record0(session, 1));

    await engine0(client).syncPendingRecords();

    final recordRequests = client.requests
        .where((request) => request.url.path.endsWith('/attendance_records'))
        .toList();
    expect(recordRequests, hasLength(1));
    expect(recordRequests.single.url.queryParameters['on_conflict'], 'id');

    final payload = (jsonDecode(recordRequests.single.body) as List<dynamic>)
        .single as Map<String, dynamic>;
    expect(payload['id'], 'record-session-identity-1');
    expect(payload['student_id'], 'student-1');
  });
}

class _FakeSupabaseHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request, String body)
      _handle;
  final requests = <_CapturedRequest>[];

  _FakeSupabaseHttpClient(this._handle);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    requests.add(
      _CapturedRequest(
        method: request.method,
        url: request.url,
        body: body,
      ),
    );
    final response = await _handle(request, body);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

class _CapturedRequest {
  final String method;
  final Uri url;
  final String body;

  const _CapturedRequest({
    required this.method,
    required this.url,
    required this.body,
  });
}
