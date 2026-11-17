import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/attendance_models.dart';
import '../services/biometric_service.dart';
import '../services/local_database_service.dart';
import '../services/pin_security_service.dart';
import '../services/sync_engine_service.dart';

final localDatabaseProvider = Provider<LocalDatabaseService>((ref) {
  return LocalDatabaseService();
});

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});

final pinSecurityProvider = Provider<PinSecurityService>((ref) {
  return PinSecurityService();
});

final syncEngineProvider = Provider<SyncEngineService>((ref) {
  final db = ref.watch(localDatabaseProvider);
  final supabase = Supabase.instance.client;
  final engine = SyncEngineService(db, supabase);
  ref.onDispose(engine.dispose);
  return engine;
});

class SessionState {
  final Lecture? activeLecture;
  final AttendanceSession? activeSession;
  final List<Student> roster;
  final Map<String, AttendanceRecord> recordsByStudentId;
  final int pendingSyncCount;
  final bool isSyncing;
  final NetworkTransport networkTransport;
  final SyncProgress? syncProgress;

  const SessionState({
    this.activeLecture,
    this.activeSession,
    this.roster = const [],
    this.recordsByStudentId = const {},
    this.pendingSyncCount = 0,
    this.isSyncing = false,
    this.networkTransport = NetworkTransport.offline,
    this.syncProgress,
  });

  int get enrolledCount => roster.length;
  int get checkedInCount => recordsByStudentId.values
      .where((r) => r.status == AttendanceStatus.present || r.status == AttendanceStatus.late)
      .length;
  int get absentCount => enrolledCount - checkedInCount;

  SessionState copyWith({
    Lecture? activeLecture,
    AttendanceSession? activeSession,
    List<Student>? roster,
    Map<String, AttendanceRecord>? recordsByStudentId,
    int? pendingSyncCount,
    bool? isSyncing,
    NetworkTransport? networkTransport,
    SyncProgress? syncProgress,
    bool clearSyncProgress = false,
  }) =>
      SessionState(
        activeLecture: activeLecture ?? this.activeLecture,
        activeSession: activeSession ?? this.activeSession,
        roster: roster ?? this.roster,
        recordsByStudentId: recordsByStudentId ?? this.recordsByStudentId,
        pendingSyncCount: pendingSyncCount ?? this.pendingSyncCount,
        isSyncing: isSyncing ?? this.isSyncing,
        networkTransport: networkTransport ?? this.networkTransport,
        syncProgress: clearSyncProgress ? null : (syncProgress ?? this.syncProgress),
      );
}

class LectureSessionNotifier extends StateNotifier<SessionState> {
  final LocalDatabaseService _db;
  final BiometricService _biometrics;
  final SyncEngineService _syncEngine;
  final _uuid = const Uuid();

  LectureSessionNotifier(this._db, this._biometrics, this._syncEngine)
      : super(const SessionState()) {
    _bindConnectivityAutoSync();
  }

  void _bindConnectivityAutoSync() {
    Future.microtask(() async {
      final initialTransport = await _syncEngine.currentTransport();
      final pendingCount = await _db.getPendingSyncCount();
      state = state.copyWith(
        networkTransport: initialTransport,
        pendingSyncCount: pendingCount,
      );

      _syncEngine.startAutoSyncListener(
        onConnectivityChanged: (transport) {
          state = state.copyWith(networkTransport: transport);
        },
        onBatchProgress: (progress) {
          state = state.copyWith(
            isSyncing: true,
            syncProgress: progress,
            pendingSyncCount: progress.totalQueued - progress.uploadedCount,
          );
        },
        onSyncComplete: (result) async {
          final remaining = await _db.getPendingSyncCount();
          state = state.copyWith(
            isSyncing: false,
            pendingSyncCount: remaining,
            networkTransport: result.transport,
            clearSyncProgress: true,
          );
        },
      );
    });
  }

  Future<void> startPassModeSession({
    required Lecture lecture,
    required List<Student> students,
  }) async {
    await _db.cacheLectureRoster(lecture, students);
    final alphabetical = await _db.getAlphabeticalRoster(lecture.id);

    final session = AttendanceSession(
      id: _uuid.v4(),
      lectureId: lecture.id,
      teacherId: lecture.teacherId,
      startedAt: DateTime.now(),
      isLockedPassMode: true,
      enrolledCount: alphabetical.length,
    );
    await _db.upsertSession(session);

    final pendingCount = await _db.getPendingSyncCount();
    final transport = await _syncEngine.currentTransport();

    state = SessionState(
      activeLecture: lecture,
      activeSession: session,
      roster: alphabetical,
      recordsByStudentId: const {},
      pendingSyncCount: pendingCount,
      networkTransport: transport,
    );
  }

  /// Tapping a student row runs native local_auth and commits to SQLite WAL immediately.
  Future<BiometricVerificationResult> checkInStudentWithBiometrics(
    Student student,
  ) async {
    final session = state.activeSession;
    final lecture = state.activeLecture;
    if (session == null || lecture == null) {
      return const BiometricVerificationResult(
        verified: false,
        method: 'none',
        errorMessage: 'No active lecture session.',
      );
    }

    final existing = state.recordsByStudentId[student.id];
    if (existing != null && existing.isLocked) {
      return const BiometricVerificationResult(
        verified: false,
        method: 'locked',
        errorMessage: 'Student already checked in and locked.',
      );
    }

    final result = await _biometrics.verifyStudentIdentity(
      studentName: student.displayName,
    );

    if (!result.verified) return result;

    final now = DateTime.now();
    final elapsedMinutes = now.difference(session.startedAt).inMinutes;
    final status = elapsedMinutes > lecture.lateGraceMinutes
        ? AttendanceStatus.late
        : AttendanceStatus.present;

    final record = AttendanceRecord(
      id: existing?.id ?? _uuid.v4(),
      sessionId: session.id,
      lectureId: lecture.id,
      studentId: student.id,
      status: status,
      checkedInAt: now,
      biometricVerified: true,
      biometricMethod: result.method,
      syncStatus: SyncStatus.pending,
      deviceRecordedAt: now,
    );

    await _db.upsertAttendanceRecord(record);
    final pendingCount = await _db.getPendingSyncCount();

    state = state.copyWith(
      recordsByStudentId: {
        ...state.recordsByStudentId,
        student.id: record,
      },
      pendingSyncCount: pendingCount,
    );

    return result;
  }

  Future<void> teacherOverrideStatus({
    required Student student,
    required AttendanceStatus status,
    String? reason,
  }) async {
    final session = state.activeSession;
    final lecture = state.activeLecture;
    if (session == null || lecture == null) return;

    final existing = state.recordsByStudentId[student.id];
    final now = DateTime.now();

    final record = AttendanceRecord(
      id: existing?.id ?? _uuid.v4(),
      sessionId: session.id,
      lectureId: lecture.id,
      studentId: student.id,
      status: status,
      checkedInAt: status == AttendanceStatus.present || status == AttendanceStatus.late
          ? (existing?.checkedInAt ?? now)
          : null,
      biometricVerified: existing?.biometricVerified ?? false,
      biometricMethod: 'manual_override',
      overrideReason: reason,
      syncStatus: SyncStatus.pending,
      deviceRecordedAt: now,
    );

    await _db.upsertAttendanceRecord(record);
    final pendingCount = await _db.getPendingSyncCount();

    state = state.copyWith(
      recordsByStudentId: {
        ...state.recordsByStudentId,
        student.id: record,
      },
      pendingSyncCount: pendingCount,
    );
  }

  Future<SyncResult> syncNow() async {
    state = state.copyWith(isSyncing: true);
    final result = await _syncEngine.syncPendingRecords(
      onBatchProgress: (progress) {
        state = state.copyWith(
          isSyncing: true,
          syncProgress: progress,
          pendingSyncCount: progress.totalQueued - progress.uploadedCount,
        );
      },
    );
    final pendingCount = await _db.getPendingSyncCount();
    state = state.copyWith(
      isSyncing: false,
      pendingSyncCount: pendingCount,
      networkTransport: result.transport,
      clearSyncProgress: true,
    );
    return result;
  }
}

final lectureSessionProvider =
    StateNotifierProvider<LectureSessionNotifier, SessionState>((ref) {
  return LectureSessionNotifier(
    ref.watch(localDatabaseProvider),
    ref.watch(biometricServiceProvider),
    ref.watch(syncEngineProvider),
  );
});
