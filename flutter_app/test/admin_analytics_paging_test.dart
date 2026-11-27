import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/screens/admin_analytics_screen.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late LocalDatabaseService database;
  late _OfflineSyncEngine sync;
  late LectureSessionNotifier notifier;
  late List<_Call> calls;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    sync = _OfflineSyncEngine(database);
    notifier = LectureSessionNotifier(database, BiometricService(), sync);
    await notifier.initialization;
    calls = [];
  });

  tearDown(() async {
    sync.dispose();
    await database.close();
  });

  Map<String, dynamic> logRow(int index) => {
        'course_code': 'BIO-$index',
        'lecture_title': 'Lecture',
        'teacher_name': 'Teacher',
        'session_date': '2026-11-01',
        'submitted_to_cloud_at': null,
        'biometric_checked_in_count': 28,
        'enrolled_snapshot_count': 30,
      };

  Map<String, dynamic> attendanceRow(int index) => {
        'id': 'record-$index',
        'session_id': 'session-$index',
        'lecture_id': 'lecture-$index',
        'student_id': 'student-$index',
        'status': 'present',
      };

  SupabaseClient buildClient() => SupabaseClient(
        'https://lectureguard.test',
        'test-key',
        // Without this the client starts an auto-refresh timer that outlives
        // the widget tree and fails the test with a pending-timer assertion.
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final params = request.body.isEmpty
              ? const <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          calls.add(_Call(request.url, params));
          if (request.url.path.endsWith('/rpc/teacher_submission_logs')) {
            final offset = (params['p_offset'] as num?)?.toInt() ?? 0;
            final count = offset == 0 ? 50 : 4;
            return _json(
              List.generate(count, (index) => logRow(offset + index)),
              request,
            );
          }
          if (request.url.path.endsWith('/attendance_records')) {
            final offset =
                int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
            final count = offset == 0 ? 50 : 1;
            return _json(
              List.generate(count, (index) => attendanceRow(offset + index)),
              request,
            );
          }
          return _json(const [], request);
        }),
      );

  Widget wrap(SupabaseClient client) => ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(home: AdminAnalyticsScreen(client: client)),
      );

  test('the logs stub decodes to a full page', () async {
    final client = buildClient();
    final rows = await client.rpc(
      'teacher_submission_logs',
      params: {'p_limit': 50, 'p_offset': 0},
    );
    expect(rows, hasLength(50));
  });

  testWidgets('teacher log paging requests 50 rows per page and appends them',
      (tester) async {
    // postgrest hands payloads over 10 kB to a background isolate, and isolate
    // replies are never delivered inside a widget test's fake-async zone, so
    // the stubbed page has to stay under that threshold to decode in-process.
    expect(
      jsonEncode(List.generate(50, (index) => logRow(index))).length,
      lessThan(10000),
    );

    await tester.pumpWidget(wrap(buildClient()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Teacher Logs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    List<_Call> logCalls() => calls
        .where((call) => call.url.path.endsWith('/rpc/teacher_submission_logs'))
        .toList();
    expect(logCalls(), hasLength(1));
    expect(logCalls().single.params['p_limit'], 50);
    expect(logCalls().single.params['p_offset'], 0);
    expect(find.text('BIO-0 · Lecture'), findsOneWidget);

    // Scroll to the end of the list; dragUntilVisible rebuilds dozens of times
    // and is prohibitively slow on the ffi test runtime.
    final listFinder = find.descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    );
    for (var i = 0; i < 4; i++) {
      await tester.drag(listFinder.first, const Offset(0, -1200));
      await tester.pump();
    }
    // Explicit pumps: a progress indicator keeps animating, so pumpAndSettle
    // would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Load more submission logs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(logCalls(), hasLength(2));
    expect(logCalls().last.params['p_offset'], 50);
    // The second page is short, so the screen stops offering "load more".
    expect(find.text('Load more submission logs'), findsNothing);
  });

  testWidgets('chronic-absence paging sends the debounced search filter',
      (tester) async {
    await tester.pumpWidget(wrap(buildClient()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).first, 'STU-1');
    // The search box debounces for 350ms before reloading.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    printOnFailure('search: ${_texts(tester)}');

    final chronicCalls = calls
        .where((call) =>
            call.url.path.endsWith('/rpc/admin_chronic_absentee_page'))
        .toList();
    expect(chronicCalls.length, greaterThanOrEqualTo(2));
    expect(chronicCalls.last.params['p_search'], 'STU-1');
  });

  testWidgets('an empty chronic-absence page shows the empty state',
      (tester) async {
    await tester.pumpWidget(wrap(buildClient()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    printOnFailure('empty: ${_texts(tester)}');
    expect(find.text('No students match these filters.'), findsOneWidget);
  });

  testWidgets('School Management keeps existing tabs and adds admin management',
      (tester) async {
    await tester.pumpWidget(wrap(buildClient()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.tabs, hasLength(6));
    expect(find.text('Courses & Lecturers'), findsOneWidget);
    expect(find.text('Admin Management'), findsOneWidget);
    expect(find.text('School Records'), findsOneWidget);

    await tester.ensureVisible(find.text('Admin Management'));
    await tester.pump();
    await tester.tap(find.text('Admin Management'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.textContaining('Create new accounts in Supabase Auth first.'),
      findsOneWidget,
    );
  });

  testWidgets('School Records loads attendance rows in pages', (tester) async {
    final client = buildClient();
    await tester.pumpWidget(wrap(client));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.ensureVisible(find.text('School Records'));
    await tester.pump();
    await tester.tap(find.text('School Records'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('present · student student-0'), findsOneWidget);
    final schoolRecordsList = find.byType(ListView).last;
    for (var i = 0; i < 6; i++) {
      await tester.drag(schoolRecordsList, const Offset(0, -1000));
      await tester.pump();
    }
    expect(find.text('Load more rows'), findsOneWidget);
    await tester.tap(find.text('Load more rows'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final attendanceCalls = calls
        .where((call) => call.url.path.endsWith('/attendance_records'))
        .toList();
    expect(attendanceCalls, hasLength(2));
    expect(attendanceCalls.last.url.queryParameters['offset'], '50');
    expect(find.text('present · student student-50'), findsOneWidget);
    expect(find.text('Load more rows'), findsNothing);
  });
}

List<String?> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .toList();

http.Response _json(Object body, [http.BaseRequest? request]) => http.Response(
      jsonEncode(body),
      200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        // postgrest's .range() asks for an exact count and reads it from this
        // header.
        'content-range': '0-49/50',
      },
      // MockClient forwards `response.request`, and postgrest inspects
      // `response.request.method`; without it parsing throws a null check.
      request: request,
    );

class _Call {
  const _Call(this.url, this.params);

  final Uri url;
  final Map<String, dynamic> params;
}

class _OfflineSyncEngine extends SyncEngineService {
  _OfflineSyncEngine(LocalDatabaseService database)
      : super(
          database,
          SupabaseClient(
            'https://example.supabase.co',
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
