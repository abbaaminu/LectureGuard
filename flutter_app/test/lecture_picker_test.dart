import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/screens/lecture_picker_screen.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _lectures = [
  Lecture(
    id: 'lecture-1',
    courseCode: 'BIO-101',
    title: 'Cell Biology',
    teacherId: 'teacher-1',
    teacherName: 'Teacher One',
    roomNumber: 'A1',
    periodNumber: 2,
  ),
  Lecture(
    id: 'lecture-2',
    courseCode: 'CHM-102',
    title: 'Organic Chemistry',
    teacherId: 'teacher-1',
    teacherName: 'Teacher One',
    roomNumber: 'B2',
    periodNumber: 4,
  ),
];

const _roster = [
  Student(
    id: 'student-1',
    studentCode: 'STU-1',
    firstName: 'Amir',
    lastName: 'Alvarez',
    gradeLevel: 13,
    homeroom: 'Y1-A',
  ),
];

void main() {
  late LocalDatabaseService database;
  late _OfflineSyncEngine sync;
  late _FakeLectureSessionNotifier notifier;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    sync = _OfflineSyncEngine(database);
    notifier = _FakeLectureSessionNotifier(database, sync);
    await notifier.initialization;
  });

  tearDown(() async {
    sync.dispose();
    await database.close();
  });

  Future<void> openPicker(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lectureSessionProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LecturePickerScreen(),
                  ),
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the teacher lectures and selects one with its roster',
      (tester) async {
    await openPicker(tester);

    expect(find.text('Choose a lecture'), findsOneWidget);
    expect(find.text('BIO-101 · Cell Biology'), findsOneWidget);
    expect(find.text('CHM-102 · Organic Chemistry'), findsOneWidget);

    await tester.tap(find.text('BIO-101 · Cell Biology'));
    await tester.pumpAndSettle();

    expect(find.text('1 students cached'), findsOneWidget);
    expect(notifier.rosterLecture, 'lecture-1');

    await tester.tap(find.text('Use this lecture'));
    await tester.pumpAndSettle();

    expect(find.text('Open picker'), findsOneWidget);
    expect(notifier.selectedLecture?.id, 'lecture-1');
    expect(notifier.state.activeLecture?.id, 'lecture-1');
    expect(notifier.state.roster.single.id, 'student-1');
  });

  testWidgets('shows the error panel and recovers when retried',
      (tester) async {
    notifier.failLectures = true;
    await openPicker(tester);

    expect(find.textContaining('Could not load assigned lectures:'),
        findsOneWidget);

    notifier.failLectures = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('BIO-101 · Cell Biology'), findsOneWidget);
  });
}

class _FakeLectureSessionNotifier extends LectureSessionNotifier {
  _FakeLectureSessionNotifier(LocalDatabaseService database, SyncEngineService sync)
      : super(database, BiometricService(), sync);

  bool failLectures = false;
  Lecture? selectedLecture;
  String? rosterLecture;

  @override
  Future<void> loadTeacherLectures() async {
    // Deferred: the picker calls this from initState, and Riverpod forbids
    // modifying the provider while the widget tree is building.
    await Future<void>.delayed(Duration.zero);
    if (failLectures) {
      throw StateError('offline and nothing cached');
    }
    state = state.copyWith(availableLectures: _lectures);
  }

  @override
  Future<List<Student>> loadLectureRoster(Lecture lecture) async {
    rosterLecture = lecture.id;
    return _roster;
  }

  @override
  void selectLecture(Lecture lecture, List<Student> students) {
    selectedLecture = lecture;
    super.selectLecture(lecture, students);
  }
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
