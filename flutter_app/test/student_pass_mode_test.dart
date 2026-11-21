import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/screens/student_pass_mode_screen.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/pass_mode_lock_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';

void main() {
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
    sync = _OfflineSyncEngine(database);
    notifier = LectureSessionNotifier(database, BiometricService(), sync);
    await notifier.initialization;

    const lecture = Lecture(
      id: 'lecture-300',
      courseCode: 'BIO-300',
      title: 'Biology',
      teacherId: 'teacher-1',
      teacherName: 'Teacher',
      roomNumber: 'A1',
      periodNumber: 1,
    );
    final students = List.generate(
      300,
      (index) => Student(
        id: 'student-${index.toString().padLeft(3, '0')}',
        studentCode: 'STU-${index.toString().padLeft(3, '0')}',
        firstName: 'Learner ${index.toString().padLeft(3, '0')}',
        lastName: index == 0
            ? 'Álvarez000'
            : 'Student${index.toString().padLeft(3, '0')}',
        gradeLevel: 10,
        homeroom: '10A',
      ),
    );
    await notifier.startPassModeSession(
      lecture: lecture,
      students: students,
    );
    // Pass Mode is active for every rendered roster; the lock service is
    // injected per test so no platform channel is touched.
    await notifier.lockPassMode();
  });

  tearDown(() async {
    sync.dispose();
    await database.close();
  });

  testWidgets('renders and searches a 300-student virtualized roster',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: const MaterialApp(home: StudentPassModeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
        find.text('Checked In: 0/300 · Offline (SQLite WAL)'), findsOneWidget);
    expect(find.text('Álvarez000, Learner 000'), findsOneWidget);

    expect(find.byKey(const Key('pass-mode-roster-list')), findsOneWidget);
    expect(find.text('Student299, Learner 299'), findsNothing);

    await tester.enterText(find.byType(TextField), 'á');
    await tester.pumpAndSettle();
    expect(find.text('Álvarez000, Learner 000'), findsOneWidget);
    expect(find.text('Student299, Learner 299'), findsNothing);
  });

  testWidgets('keeps a persistent banner when the device will not lock',
      (tester) async {
    final lock = _StubLockService(PassModeLockState.failed);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(home: StudentPassModeScreen(lockService: lock)),
      ),
    );
    await tester.pumpAndSettle();

    expect(lock.startCalls, 1);
    expect(find.byKey(const Key('pass-mode-lock-warning')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    // A snackbar would have vanished long before this point; the banner stays.
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const Key('pass-mode-lock-warning')), findsOneWidget);
    expect(
      find.textContaining('could not lock this device'),
      findsOneWidget,
    );
  });

  testWidgets('shows no banner when the device is a locked kiosk',
      (tester) async {
    final lock = _StubLockService(PassModeLockState.locked);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(home: StudentPassModeScreen(lockService: lock)),
      ),
    );
    await tester.pumpAndSettle();

    expect(lock.startCalls, 1);
    expect(find.byKey(const Key('pass-mode-lock-warning')), findsNothing);
  });
}

class _StubLockService extends PassModeLockService {
  _StubLockService(this.state);

  final PassModeLockState state;
  int startCalls = 0;

  @override
  Future<PassModeLockState> start() async {
    startCalls++;
    return state;
  }

  @override
  Future<void> stop() async {}
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
