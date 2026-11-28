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
    await database.cacheLectures(_lectures);
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
          // The enroll action re-reads the roster through the database
          // provider; point it at the test database instead of opening the
          // real on-device database file.
          localDatabaseProvider.overrideWithValue(database),
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
    await _pumpUntilFound(tester, find.text('BIO-101 · Cell Biology'));
  }

  testWidgets('lists the teacher lectures and selects one with its roster',
      (tester) async {
    await openPicker(tester);

    expect(find.text('Choose a lecture'), findsOneWidget);
    expect(find.text('BIO-101 · Cell Biology'), findsOneWidget);
    expect(find.text('CHM-102 · Organic Chemistry'), findsOneWidget);

    await tester.tap(find.text('BIO-101 · Cell Biology'));
    await _pumpUntilFound(tester, find.text('1 students cached'));

    expect(find.text('1 students cached'), findsOneWidget);
    expect(notifier.rosterLecture, 'lecture-1');

    await tester.tap(find.text('Use this lecture'));
    await _pumpUntil(
      tester,
      () => find.text('Choose a lecture').evaluate().isEmpty,
    );

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

  testWidgets('empty assignments explain admin setup and can be refreshed',
      (tester) async {
    notifier.lectures = const [];
    await openPicker(tester);

    expect(
      find.textContaining('No courses have been assigned to your account'),
      findsOneWidget,
    );
    expect(find.textContaining('Contact an admin'), findsOneWidget);
    expect(find.text('Refresh / sync courses'), findsOneWidget);

    notifier.lectures = _lectures;
    await tester.tap(find.text('Refresh / sync courses'));
    await tester.pumpAndSettle();
    expect(find.text('BIO-101 · Cell Biology'), findsOneWidget);
  });

  testWidgets('teacher can enroll a student through device verification',
      (tester) async {
    await openPicker(tester);
    await tester.tap(find.text('BIO-101 · Cell Biology'));
    await _pumpUntilFound(tester, find.text('1 students cached'));

    await tester.enterText(find.byType(TextField).first, 'Amina Bello');
    await tester.enterText(find.byType(TextField).last, 'REG-42');
    await tester.ensureVisible(find.text('Verify & Enroll Student'));
    await tester.tap(find.text('Verify & Enroll Student'));
    await _pumpUntilFound(
      tester,
      find.textContaining('Student saved on this device'),
      realAsync: true,
    );

    expect(notifier.enrolledStudent?.displayName, 'Amina Bello');
    expect(notifier.enrolledStudent?.studentCode, 'REG-42');
    expect(
      notifier.enrolledStudent?.biometricEnrollmentMethod,
      'fingerprint',
    );

    // The database uses real async I/O, so it must be awaited through
    // `runAsync`; awaiting it directly in the fake-async test zone leaves the
    // binding unable to pump the final post-test frame.
    final persistedRoster = await tester.runAsync(
      () => database.getAlphabeticalRoster('lecture-1'),
    );
    expect(persistedRoster?.single.displayName, 'Amina Bello');
    expect(persistedRoster?.single.studentCode, 'REG-42');
  });
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  bool realAsync = false,
}) =>
    _pumpUntil(
      tester,
      () => finder.evaluate().isNotEmpty,
      realAsync: realAsync,
    );

/// Advances fake time until [condition] is satisfied.
///
/// `pumpAndSettle` cannot be used on this screen because the lecture picker
/// keeps a persistent refresh indicator. Pass `realAsync: true` when the
/// condition depends on real I/O (such as a database write); a plain
/// fake-async `pump` never lets real work complete.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  bool realAsync = false,
}) async {
  final attempts = realAsync ? 40 : 10;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (condition()) return;
    if (realAsync) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _FakeLectureSessionNotifier extends LectureSessionNotifier {
  _FakeLectureSessionNotifier(
    this.database,
    SyncEngineService sync,
  ) : super(
          database,
          BiometricService(),
          sync,
          currentUserId: () => 'teacher-1',
        );

  final LocalDatabaseService database;
  bool failLectures = false;
  List<Lecture> lectures = _lectures;
  Lecture? selectedLecture;
  String? rosterLecture;
  Student? enrolledStudent;

  @override
  Future<void> loadTeacherLectures() async {
    // Deferred: the picker calls this from initState, and Riverpod forbids
    // modifying the provider while the widget tree is building.
    await Future<void>.delayed(Duration.zero);
    if (failLectures) {
      throw StateError('offline and nothing cached');
    }
    state = state.copyWith(availableLectures: lectures);
  }

  @override
  Future<List<Student>> loadLectureRoster(Lecture lecture) async {
    rosterLecture = lecture.id;
    return _roster;
  }

  @override
  Future<StudentEnrollmentResult> enrollStudentInLecture({
    required Lecture lecture,
    required String studentName,
    required String studentCode,
  }) async {
    final nameParts = studentName.trim().split(' ');
    final student = Student(
      id: 'student-new',
      studentCode: studentCode,
      firstName: nameParts.first,
      lastName: nameParts.skip(1).join(' '),
      biometricEnrollmentCapturedAt: DateTime.now(),
      biometricEnrollmentMethod: 'fingerprint',
    );
    await database.savePendingTeacherEnrollment(
      lectureId: lecture.id,
      teacherId: lecture.teacherId,
      student: student,
    );
    enrolledStudent = student;
    return StudentEnrollmentResult(
      student: student,
      syncedToCloud: false,
    );
  }

  @override
  Future<String?> validateLectureAssignmentLocally(Lecture? lecture) async =>
      null;

  @override
  Future<void> selectLecture(Lecture lecture, List<Student> students) async {
    selectedLecture = lecture;
    state = state.copyWith(activeLecture: lecture, roster: students);
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
