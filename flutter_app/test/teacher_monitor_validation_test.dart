import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/screens/teacher_monitor_screen.dart';
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
    roomNumber: 'TBD',
    periodNumber: 1,
    academicTerm: '2026-T1',
  );
  const student = Student(
    id: 'student-1',
    studentCode: 'STU-1',
    firstName: 'Amina',
    lastName: 'Bello',
    gradeLevel: 10,
    homeroom: '10A',
  );

  late LocalDatabaseService database;
  late _OfflineSyncEngine sync;
  late _ValidationNotifier notifier;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    await database.cacheLectureRoster(lecture, [student]);
    sync = _OfflineSyncEngine(database);
    notifier = _ValidationNotifier(
      database,
      sync,
    );
    await notifier.initialization;
  });
  tearDown(() async {
    sync.dispose();
    await database.close();
  });

  Future<void> openMonitor(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: const MaterialApp(home: TeacherMonitorScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('blocks Start Session and explains timetable configuration',
      (tester) async {
    notifier.state = notifier.state.copyWith(
      activeLecture: lecture,
      roster: [student],
    );
    await openMonitor(tester);

    expect(
      find.text(
        'Configure this course timetable on your device before starting attendance.',
      ),
      findsOneWidget,
    );
    final startButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Start Session'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(startButton.onPressed, isNull);
    expect(find.text('Update timetable'), findsOneWidget);
  });

  testWidgets('blocks Launch Pass Mode for an unconfigured active course',
      (tester) async {
    final now = DateTime.now();
    notifier.state = notifier.state.copyWith(
      activeLecture: lecture,
      roster: [student],
      activeSession: AttendanceSession(
        id: deterministicSessionId(lecture.id, localSessionDate(now)),
        lectureId: lecture.id,
        teacherId: teacherId,
        deviceId: 'device-1',
        sessionDate: localSessionDate(now),
        startedAt: now,
        enrolledCount: 1,
      ),
    );

    await openMonitor(tester);

    expect(
      find.text(
        'Configure this course timetable on your device before starting attendance.',
      ),
      findsWidgets,
    );
    final launchButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Launch Pass Mode'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(launchButton.onPressed, isNull);
  });
}

class _ValidationNotifier extends LectureSessionNotifier {
  _ValidationNotifier(
    LocalDatabaseService database,
    SyncEngineService sync,
  ) : super(
          database,
          BiometricService(),
          sync,
          currentUserId: () => 'teacher-1',
        );

  @override
  Future<void> loadTeacherLectures() async {}

  @override
  Future<String?> validateStartSessionLocally() async =>
      'Configure this course timetable on your device before starting attendance.';

  @override
  Future<String?> validatePassModeLaunchLocally() async =>
      'Configure this course timetable on your device before starting attendance.';
}

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
