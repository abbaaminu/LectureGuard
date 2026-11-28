import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/providers/lecture_guard_providers.dart';
import 'package:lecture_guard/services/biometric_service.dart';
import 'package:lecture_guard/services/local_database_service.dart';
import 'package:lecture_guard/services/sync_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late LocalDatabaseService database;
  late _EnrollmentBiometricService biometrics;
  late LectureSessionNotifier notifier;

  const lecture = Lecture(
    id: 'lecture-1',
    courseCode: 'BIO-101',
    title: 'Cell Biology',
    teacherId: 'teacher-1',
    teacherName: 'Teacher One',
    roomNumber: 'A1',
    periodNumber: 1,
  );

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = LocalDatabaseService(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await database.database;
    await database.cacheLectures([lecture]);
    biometrics = _EnrollmentBiometricService();
    notifier = LectureSessionNotifier(
      database,
      biometrics,
      _OfflineSyncEngine(database),
      currentUserId: () => 'teacher-1',
    );
    await notifier.initialization;
  });

  tearDown(() async {
    notifier.dispose();
    await database.close();
  });

  test('biometric verification gates and persists teacher enrollment locally',
      () async {
    final result = await notifier.enrollStudentInLecture(
      lecture: lecture,
      studentName: '  Amina   Bello ',
      studentCode: ' REG-42 ',
    );

    expect(biometrics.studentName, 'Amina Bello');
    expect(biometrics.action, 'enroll');
    expect(result.syncedToCloud, isFalse);
    final roster = await database.getAlphabeticalRoster(lecture.id);
    expect(roster, hasLength(1));
    expect(roster.single.displayName, 'Amina Bello');
    expect(roster.single.studentCode, 'REG-42');
    expect(roster.single.biometricEnrollmentMethod, 'fingerprint');
    expect(roster.single.biometricEnrollmentCapturedAt, isNotNull);
    expect(
      await database.getPendingTeacherEnrollments('teacher-1'),
      hasLength(1),
    );
  });

  test('an unsuccessful biometric does not create a student or enrollment',
      () async {
    biometrics.verified = false;

    await expectLater(
      notifier.enrollStudentInLecture(
        lecture: lecture,
        studentName: 'Amina Bello',
        studentCode: 'REG-42',
      ),
      throwsStateError,
    );

    expect(await database.getAlphabeticalRoster(lecture.id), isEmpty);
    expect(
      await database.getPendingTeacherEnrollments('teacher-1'),
      isEmpty,
    );
  });
}

class _EnrollmentBiometricService extends BiometricService {
  bool verified = true;
  String? studentName;
  String? action;

  @override
  Future<BiometricVerificationResult> verifyStudentIdentity({
    required String studentName,
    String action = 'check in',
  }) async {
    this.studentName = studentName;
    this.action = action;
    return BiometricVerificationResult(
      verified: verified,
      method: 'fingerprint',
      errorMessage: verified ? null : 'Biometric verification cancelled.',
    );
  }
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
