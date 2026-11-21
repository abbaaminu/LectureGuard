import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/attendance_models.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/local_database_service.dart';
import '../services/pin_security_service.dart';
import '../services/session_ids.dart';
import '../services/sync_engine_service.dart';

final localDatabaseProvider = Provider<LocalDatabaseService>((ref) {
  return LocalDatabaseService();
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
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
  final List<Lecture> availableLectures;
  final List<Student> roster;
  final Map<String, AttendanceRecord> recordsByStudentId;
  final int pendingSyncCount;
  final bool isSyncing;
  final bool isRestoring;
  final NetworkTransport networkTransport;
  final SyncProgress? syncProgress;
  final bool excusedCountsAsAttended;
  final String? schoolSettingsError;

  const SessionState({
    this.activeLecture,
    this.activeSession,
    this.availableLectures = const [],
    this.roster = const [],
    this.recordsByStudentId = const {},
    this.pendingSyncCount = 0,
    this.isSyncing = false,
    this.isRestoring = false,
    this.networkTransport = NetworkTransport.offline,
    this.syncProgress,
    this.excusedCountsAsAttended = false,
    this.schoolSettingsError,
  });

  int get enrolledCount => roster.length;
  int get checkedInCount => recordsByStudentId.values
      .where((r) =>
          r.status == AttendanceStatus.present ||
          r.status == AttendanceStatus.late)
      .length;
  int get absentCount {
    final attended = recordsByStudentId.values.where((record) =>
        record.status == AttendanceStatus.present ||
        record.status == AttendanceStatus.late ||
        (excusedCountsAsAttended &&
            record.status == AttendanceStatus.excused));
    return (enrolledCount - attended.length).clamp(0, enrolledCount);
  }

  SessionState copyWith({
    Lecture? activeLecture,
    AttendanceSession? activeSession,
    List<Lecture>? availableLectures,
    List<Student>? roster,
    Map<String, AttendanceRecord>? recordsByStudentId,
    int? pendingSyncCount,
    bool? isSyncing,
    bool? isRestoring,
    NetworkTransport? networkTransport,
    SyncProgress? syncProgress,
    bool? excusedCountsAsAttended,
    String? schoolSettingsError,
    bool clearSyncProgress = false,
    bool clearSchoolSettingsError = false,
    bool clearActiveLecture = false,
    bool clearActiveSession = false,
    bool clearRoster = false,
    bool clearRecords = false,
  }) =>
      SessionState(
        activeLecture:
            clearActiveLecture ? null : (activeLecture ?? this.activeLecture),
        activeSession:
            clearActiveSession ? null : (activeSession ?? this.activeSession),
        availableLectures: availableLectures ?? this.availableLectures,
        roster: clearRoster ? const [] : (roster ?? this.roster),
        recordsByStudentId: clearRecords
            ? const {}
            : (recordsByStudentId ?? this.recordsByStudentId),
        pendingSyncCount: pendingSyncCount ?? this.pendingSyncCount,
        isSyncing: isSyncing ?? this.isSyncing,
        isRestoring: isRestoring ?? this.isRestoring,
        networkTransport: networkTransport ?? this.networkTransport,
        syncProgress:
            clearSyncProgress ? null : (syncProgress ?? this.syncProgress),
        excusedCountsAsAttended:
            excusedCountsAsAttended ?? this.excusedCountsAsAttended,
        schoolSettingsError: clearSchoolSettingsError
            ? null
            : (schoolSettingsError ?? this.schoolSettingsError),
      );
}

class LectureSessionNotifier extends StateNotifier<SessionState> {
  final LocalDatabaseService _db;
  final BiometricService _biometrics;
  final SyncEngineService _syncEngine;
  final _uuid = const Uuid();
  late final Future<void> initialization;
  bool _disposed = false;

  LectureSessionNotifier(this._db, this._biometrics, this._syncEngine)
      : super(const SessionState()) {
    initialization = _initialize();
  }

  void _setState(SessionState Function(SessionState current) update) {
    if (!_disposed) state = update(state);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _initialize() async {
    final initialTransport = await _syncEngine.currentTransport();
    final pendingCount = await _db.getPendingSyncCount();
    final settings = await _db.getSchoolSettings();
    _setState((current) => current.copyWith(
          networkTransport: initialTransport,
          pendingSyncCount: pendingCount,
          excusedCountsAsAttended: settings.excusedCountsAsAttended,
        ));
    if (_disposed) return;

    _syncEngine.startAutoSyncListener(
      onConnectivityChanged: (transport) {
        _setState((current) => current.copyWith(
              networkTransport: transport,
            ));
        if (transport != NetworkTransport.offline) {
          unawaited(refreshSchoolSettings().catchError((Object error) {
            _setState((current) => current.copyWith(
                  schoolSettingsError: error.toString(),
                ));
          }));
        }
      },
      onBatchProgress: (progress) {
        _setState((current) => current.copyWith(
              isSyncing: true,
              syncProgress: progress,
              pendingSyncCount: progress.totalQueued - progress.uploadedCount,
            ));
      },
      onSyncComplete: (result) async {
        final remaining = await _db.getPendingSyncCount();
        _setState((current) => current.copyWith(
              isSyncing: false,
              pendingSyncCount: remaining,
              networkTransport: result.transport,
              clearSyncProgress: true,
            ));
      },
    );
    if (initialTransport != NetworkTransport.offline) {
      try {
        await refreshSchoolSettings();
      } catch (error) {
        _setState((current) => current.copyWith(
              schoolSettingsError: error.toString(),
            ));
      }
    }
  }

  Future<void> refreshSchoolSettings() async {
    final row = await Supabase.instance.client
        .from('school_settings')
        .select('excused_counts_as_attended')
        .eq('id', 1)
        .maybeSingle();
    if (row == null) {
      throw StateError('The school-wide attendance setting is missing.');
    }
    final settings = SchoolSettings.fromMap(row);
    await _db.cacheSchoolSettings(settings);
    _setState((current) => current.copyWith(
          excusedCountsAsAttended: settings.excusedCountsAsAttended,
          clearSchoolSettingsError: true,
        ));
  }

  Future<void> updateExcusedCountsAsAttended(bool value) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Sign in before changing school settings.');
    }
    try {
      final row = await Supabase.instance.client
          .from('school_settings')
          .update({
            'excused_counts_as_attended': value,
            'updated_by': userId,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', 1)
          .select('excused_counts_as_attended')
          .single();
      final settings = SchoolSettings.fromMap(row);
      await _db.cacheSchoolSettings(settings);
      _setState((current) => current.copyWith(
            excusedCountsAsAttended: settings.excusedCountsAsAttended,
            clearSchoolSettingsError: true,
          ));
    } catch (error) {
      _setState((current) => current.copyWith(
            schoolSettingsError: error.toString(),
          ));
      rethrow;
    }
  }

  Future<void> loadTeacherLectures() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Sign in before loading assigned classes.');
    }

    if (await _syncEngine.isOnline()) {
      final rows = await Supabase.instance.client
          .from('lectures')
          .select()
          .eq('teacher_id', userId)
          .order('period_number');
      final lectures = rows.map((row) => Lecture.fromMap(row)).toList();
      await _db.cacheLectures(lectures);
      _setState((current) => current.copyWith(availableLectures: lectures));
    } else {
      final lectures = await _db.getCachedLectures(teacherId: userId);
      _setState((current) => current.copyWith(availableLectures: lectures));
    }
  }

  Future<List<Student>> loadLectureRoster(Lecture lecture) async {
    if (await _syncEngine.isOnline()) {
      final rows = await Supabase.instance.client
          .from('enrollments')
          .select(
              'students(id, student_code, first_name, last_name, grade_level, homeroom)')
          .eq('lecture_id', lecture.id)
          .eq('active', true);
      final students = rows
          .map((row) => row['students'])
          .whereType<Map<String, dynamic>>()
          .map(Student.fromMap)
          .toList();
      await _db.cacheLectureRoster(lecture, students);
      return _db.getAlphabeticalRoster(lecture.id);
    }
    return _db.getAlphabeticalRoster(lecture.id);
  }

  void selectLecture(Lecture lecture, List<Student> students) {
    if (state.activeSession?.endedAt == null && state.activeSession != null) {
      throw StateError('End the active session before changing classes.');
    }
    _setState((current) => current.copyWith(
          activeLecture: lecture,
          roster: students,
          recordsByStudentId: const {},
          clearActiveSession: true,
        ));
  }

  Future<void> restoreActiveSession(String teacherId) async {
    _setState((current) => current.copyWith(
          isRestoring: true,
          clearActiveLecture: true,
          clearActiveSession: true,
          clearRoster: true,
          clearRecords: true,
        ));
    try {
      final session = await _db.getActiveSession(teacherId);
      if (session == null) return;
      final lecture = await _db.getCachedLecture(session.lectureId);
      if (lecture == null) {
        throw StateError(
          'The cached lecture for active session ${session.id} is missing.',
        );
      }
      final roster = await _db.getAlphabeticalRoster(lecture.id);
      final records = await _db.getSessionRecords(session.id);
      _setState((current) => current.copyWith(
            activeLecture: lecture,
            activeSession: session,
            roster: roster,
            recordsByStudentId: {
              for (final record in records) record.studentId: record,
            },
          ));
    } finally {
      _setState((current) => current.copyWith(isRestoring: false));
    }
  }

  void clearActiveSessionState() {
    _setState((current) => current.copyWith(
          clearActiveLecture: true,
          clearActiveSession: true,
          clearRoster: true,
          clearRecords: true,
        ));
  }

  Future<void> startPassModeSession({
    required Lecture lecture,
    required List<Student> students,
  }) async {
    await _db.cacheLectureRoster(lecture, students);
    final alphabetical = await _db.getAlphabeticalRoster(lecture.id);
    final now = DateTime.now();
    final date = localSessionDate(now);
    final proposedSession = AttendanceSession(
      id: deterministicSessionId(lecture.id, date),
      lectureId: lecture.id,
      teacherId: lecture.teacherId,
      deviceId: _uuid.v4(),
      sessionDate: date,
      startedAt: now,
      isLockedPassMode: false,
      enrolledCount: alphabetical.length,
    );
    final session = await _db.createSessionIfAbsent(proposedSession);
    if (session.endedAt != null) {
      throw StateError('Attendance for this class has already ended today.');
    }
    final records = await _db.getSessionRecords(session.id);

    final pendingCount = await _db.getPendingSyncCount();
    final transport = await _syncEngine.currentTransport();

    _setState((current) => SessionState(
          activeLecture: lecture,
          activeSession: session,
          availableLectures: current.availableLectures,
          roster: alphabetical,
          recordsByStudentId: {
            for (final record in records) record.studentId: record,
          },
          pendingSyncCount: pendingCount,
          networkTransport: transport,
          excusedCountsAsAttended: current.excusedCountsAsAttended,
          schoolSettingsError: current.schoolSettingsError,
        ));
  }

  Future<void> lockPassMode() => _setPassModeLocked(true);

  Future<void> unlockPassMode() => _setPassModeLocked(false);

  Future<void> _setPassModeLocked(bool isLocked) async {
    final session = state.activeSession;
    if (session == null || session.endedAt != null) {
      throw StateError('There is no active attendance session.');
    }
    await _db.setSessionPassModeLocked(session.id, isLocked: isLocked);
    final pendingCount = await _db.getPendingSyncCount();
    _setState((current) => current.copyWith(
          activeSession: session.copyWith(isLockedPassMode: isLocked),
          pendingSyncCount: pendingCount,
        ));
  }

  Future<SyncResult> endSession() async {
    final session = state.activeSession;
    if (session == null) {
      throw StateError('There is no active attendance session to end.');
    }
    if (session.endedAt != null) {
      throw StateError('This attendance session has already ended.');
    }

    final endedSession = await _db.endSession(session.id);
    final records = await _db.getSessionRecords(session.id);
    final pendingCount = await _db.getPendingSyncCount();
    _setState((current) => current.copyWith(
          activeSession: endedSession,
          recordsByStudentId: {
            for (final record in records) record.studentId: record,
          },
          pendingSyncCount: pendingCount,
        ));
    return syncNow();
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
      id: existing?.id ??
          deterministicAttendanceRecordId(session.id, student.id),
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

    _setState((current) => current.copyWith(
          recordsByStudentId: {
            ...current.recordsByStudentId,
            student.id: record,
          },
          pendingSyncCount: pendingCount,
        ));
    _syncEngine.scheduleDebouncedSync();

    return result;
  }

  Future<void> teacherOverrideStatus({
    required Student student,
    required AttendanceStatus status,
    String? reason,
  }) async {
    final session = state.activeSession;
    final lecture = state.activeLecture;
    if (session == null || lecture == null || session.endedAt != null) {
      throw StateError('There is no active attendance session.');
    }

    final existing = state.recordsByStudentId[student.id];
    final requiresReason = status == AttendanceStatus.excused ||
        status == AttendanceStatus.absent ||
        existing?.biometricVerified == true;
    final normalizedReason = reason?.trim();
    if (requiresReason && (normalizedReason == null || normalizedReason.isEmpty)) {
      throw ArgumentError(
        'A reason is required for excused, absent, or biometric overrides.',
      );
    }
    final overrideBy = Supabase.instance.client.auth.currentUser?.id;
    if (overrideBy == null) {
      throw StateError('Sign in before recording a teacher override.');
    }
    final now = DateTime.now();

    final record = AttendanceRecord(
      id: existing?.id ??
          deterministicAttendanceRecordId(session.id, student.id),
      sessionId: session.id,
      lectureId: lecture.id,
      studentId: student.id,
      status: status,
      checkedInAt:
          status == AttendanceStatus.present || status == AttendanceStatus.late
              ? (existing?.checkedInAt ?? now)
              : null,
      biometricVerified: existing?.biometricVerified ?? false,
      biometricMethod: 'manual_override',
      overrideReason: normalizedReason,
      overrideBy: overrideBy,
      syncStatus: SyncStatus.pending,
      deviceRecordedAt: now,
    );

    await _db.upsertAttendanceRecord(record);
    final pendingCount = await _db.getPendingSyncCount();

    _setState((current) => current.copyWith(
          recordsByStudentId: {
            ...current.recordsByStudentId,
            student.id: record,
          },
          pendingSyncCount: pendingCount,
        ));
    _syncEngine.scheduleDebouncedSync();
  }

  Future<SyncResult> syncNow() async {
    _setState((current) => current.copyWith(isSyncing: true));
    final result = await _syncEngine.syncPendingRecords(
      onBatchProgress: (progress) {
        _setState((current) => current.copyWith(
              isSyncing: true,
              syncProgress: progress,
              pendingSyncCount: progress.totalQueued - progress.uploadedCount,
            ));
      },
    );
    final pendingCount = await _db.getPendingSyncCount();
    _setState((current) => current.copyWith(
          isSyncing: false,
          pendingSyncCount: pendingCount,
          networkTransport: result.transport,
          clearSyncProgress: true,
        ));
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
