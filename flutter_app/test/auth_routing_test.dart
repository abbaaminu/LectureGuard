import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/screens/admin_analytics_screen.dart';
import 'package:lecture_guard/screens/sign_in_screen.dart';
import 'package:lecture_guard/screens/student_attendance_screen.dart';
import 'package:lecture_guard/screens/student_pass_mode_screen.dart';
import 'package:lecture_guard/screens/teacher_monitor_screen.dart';
import 'package:lecture_guard/services/auth_service.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:lecture_guard/widgets/auth_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  });

  tearDown(() async {
    sync.dispose();
    await database.close();
  });

  test('each role routes to exactly one screen', () {
    expect(
      authGateScreenForRole(UserRole.admin, const SessionState()),
      isA<AdminAnalyticsScreen>(),
    );
    expect(
      authGateScreenForRole(UserRole.student, const SessionState()),
      isA<StudentAttendanceScreen>(),
    );
    expect(
      authGateScreenForRole(UserRole.teacher, const SessionState()),
      isA<TeacherMonitorScreen>(),
    );
    expect(
      authGateScreenForRole(null, const SessionState()),
      isNull,
      reason: 'a missing profile must fall through to the access message',
    );
  });

  test('a teacher with a locked Pass Mode session is routed to Pass Mode', () {
    final session = AttendanceSession(
      id: 'session-1',
      lectureId: 'lecture-1',
      teacherId: 'teacher-1',
      deviceId: 'device-1',
      sessionDate: '2026-11-19',
      startedAt: DateTime(2026, 11, 19, 9),
      enrolledCount: 30,
    );
    final screen = authGateScreenForRole(
      UserRole.teacher,
      SessionState(activeSession: session),
    );
    expect(screen, isA<StudentPassModeScreen>());
    expect((screen! as StudentPassModeScreen).authGateManaged, isTrue);
  });

  testWidgets('sign-in validates input and sends the trimmed address',
      (tester) async {
    final auth = _RecordingAuthService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );

    await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
    await tester.enterText(find.byType(TextFormField).last, 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(auth.signInCalls, 0);

    await tester.enterText(
      find.byType(TextFormField).first,
      ' teacher@school.test ',
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 1);
    expect(auth.email, 'teacher@school.test');
    expect(auth.password, 'secret');
  });

  testWidgets('sign-in surfaces the Supabase error message', (tester) async {
    final auth = _RecordingAuthService(
      error: const AuthException('Invalid login credentials'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );

    await tester.enterText(
      find.byType(TextFormField).first,
      'teacher@school.test',
    );
    await tester.enterText(find.byType(TextFormField).last, 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid login credentials'), findsOneWidget);
  });

  testWidgets('AuthGate shows the sign-in screen without a session',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(_SignedOutAuthService()),
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in with your school account.'), findsOneWidget);
    expect(find.byType(SignInScreen), findsOneWidget);
  });
}

class _RecordingAuthService extends AuthService {
  _RecordingAuthService({this.error})
      : super(
        client: SupabaseClient(
          'https://lectureguard.test',
          'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  final Object? error;
  int signInCalls = 0;
  String? email;
  String? password;

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    this.email = email;
    this.password = password;
    if (error != null) throw error!;
  }

  @override
  Future<void> signOut() async {}
}

class _SignedOutAuthService extends AuthService {
  _SignedOutAuthService()
      : super(
        client: SupabaseClient(
          'https://lectureguard.test',
          'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  @override
  Session? get currentSession => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<void> signOut() async {}
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
