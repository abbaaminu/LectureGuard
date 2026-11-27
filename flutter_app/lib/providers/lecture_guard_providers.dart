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

String? _signedInUserId() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

final localDatabaseProvider = Provider<LocalDatabaseService>((ref) {
  return LocalDatabaseService();
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(database: ref.watch(localDatabaseProvider));
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
        (excusedCountsAsAttended && record.status == AttendanceStatus.excused));
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
  final String? Function() _currentUserId;
  final _uuid = const Uuid();
  late final Future<void> initialization;
  bool _disposed = false;
  bool _schoolSettingsLoadedFromNetwork = false;

  LectureSessionNotifier(
    this._db,
    this._biometrics,
    this._syncEngine, {
    String? Function()? currentUserId,
  })  : _currentUserId = currentUserId ?? _signedInUserId,
        super(const SessionState()) {
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
        if (transport != NetworkTransport.offline && hasSignedInUser) {
          unawaited(refreshSchoolSettings().catchError((Object error) {
            reportSchoolSettingsError(error);
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
    if (initialTransport != NetworkTransport.offline && hasSignedInUser) {
      try {
        await refreshSchoolSettings();
      } catch (error) {
        reportSchoolSettingsError(error);
      }
    }
  }

  /// `school_settings` is only readable by signed-in accounts, so an anonymous
  /// start-up must fall back to the cached row. Requesting it before sign-in
  /// always failed with "permission denied for table school_settings" and left
  /// an error banner on the first dashboard the user opened. Returns false when
  /// Supabase itself is not initialised (unit tests, startup failure).
  bool get hasSignedInUser {
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  /// Refreshes the school-wide setting once a session exists. The start-up pass
  /// already succeeds when a session was restored, so this only repeats a
  /// failed or skipped attempt instead of fetching the same row twice.
  Future<void> ensureSchoolSettingsFresh() async {
    if (_schoolSettingsLoadedFromNetwork && state.schoolSettingsError == null) {
      return;
    }
    try {
      await refreshSchoolSettings();
    } catch (error) {
      reportSchoolSettingsError(error);
    }
  }

  /// Records a failed settings refresh so the dashboard banner can surface it.
  void reportSchoolSettingsError(Object error) {
    _setState((current) => current.copyWith(
          schoolSettingsError: error.toString(),
        ));
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
    _schoolSettingsLoadedFromNetwork = true;
    _setState((current) => current.copyWith(
          excusedCountsAsAttended: settings.excusedCountsAsAttended,
          clearSchoolSettingsError: true,
        ));
  }

  Future<void> updateExcusedCountsAsAttended(bool value) async {
    final userId = _currentUserId();
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
      reportSchoolSettingsError(error);
      rethrow;
    }
  }

  Future<List<TeacherProfile>> loadTeacherProfiles({
    SupabaseClient? client,
  }) async {
    final rows = await (client ?? Supabase.instance.client)
        .from('profiles')
        .select('id, full_name, email')
        .eq('role', 'teacher')
        .order('full_name');
    return rows.map((row) => TeacherProfile.fromMap(row)).toList();
  }

  Future<List<Map<String, dynamic>>> loadAdminProfiles({
    SupabaseClient? client,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    const pageSize = 500;
    final profiles = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final rows = await supabase
          .from('profiles')
          .select('id, full_name, email, role')
          .order('full_name')
          .range(offset, offset + pageSize - 1);
      profiles.addAll(rows.map((row) => Map<String, dynamic>.from(row)));
      if (rows.length < pageSize) break;
      offset += pageSize;
    }
    await _db.cacheAdminProfiles(profiles);
    return profiles;
  }

  Future<void> setAdminProfileRole({
    required String profileId,
    required String email,
    required UserRole role,
    SupabaseClient? client,
  }) async {
    final result = await (client ?? Supabase.instance.client).rpc(
      'admin_set_user_role',
      params: {'p_email': email, 'p_role': role.name},
    );
    if (result == null || result.toString() != profileId) {
      throw StateError('The role update did not return the expected profile.');
    }

    final cachedProfiles = await _db.getCachedAdminProfiles();
    final profiles = cachedProfiles
        .map((profile) => Map<String, dynamic>.from(profile))
        .toList();
    final index = profiles.indexWhere((profile) => profile['id'] == profileId);
    if (index >= 0) {
      profiles[index]['role'] = role.name;
      await _db.cacheAdminProfiles(profiles);
    }
    await _db.cacheUserProfileRole(profileId, role.name);
  }

  Future<List<Map<String, dynamic>>> loadAdminStudents({
    SupabaseClient? client,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    const pageSize = 500;
    final students = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final rows = await supabase
          .from('students')
          .select(
              'id, profile_id, student_code, first_name, last_name, grade_level, homeroom, active')
          .order('last_name')
          .order('first_name')
          .range(offset, offset + pageSize - 1);
      students.addAll(rows.map((row) => Map<String, dynamic>.from(row)));
      if (rows.length < pageSize) break;
      offset += pageSize;
    }
    await _db.cacheAdminStudents(students);
    return students;
  }

  Future<Map<String, dynamic>> createAdminStudent({
    required String studentCode,
    required String firstName,
    required String lastName,
    required int gradeLevel,
    required String homeroom,
    SupabaseClient? client,
  }) async {
    final values = _validatedAdminStudentValues(
      studentCode: studentCode,
      firstName: firstName,
      lastName: lastName,
      gradeLevel: gradeLevel,
      homeroom: homeroom,
      active: true,
    );
    final row = await (client ?? Supabase.instance.client)
        .from('students')
        .insert(values)
        .select(
            'id, profile_id, student_code, first_name, last_name, grade_level, homeroom, active')
        .single();
    final student = Map<String, dynamic>.from(row);
    await _db.cacheAdminStudent(student);
    return student;
  }

  Future<Map<String, dynamic>> updateAdminStudent({
    required String studentId,
    required String studentCode,
    required String firstName,
    required String lastName,
    required int gradeLevel,
    required String homeroom,
    required bool active,
    SupabaseClient? client,
  }) async {
    final values = _validatedAdminStudentValues(
      studentCode: studentCode,
      firstName: firstName,
      lastName: lastName,
      gradeLevel: gradeLevel,
      homeroom: homeroom,
      active: active,
    );
    final row = await (client ?? Supabase.instance.client)
        .from('students')
        .update(values)
        .eq('id', studentId)
        .select(
            'id, profile_id, student_code, first_name, last_name, grade_level, homeroom, active')
        .single();
    final student = Map<String, dynamic>.from(row);
    await _db.cacheAdminStudent(student);
    return student;
  }

  /// Links a student record to the Supabase auth profile used by the student
  /// self-service screen. Passing null unlinks the account.
  Future<Map<String, dynamic>> setAdminStudentProfile({
    required String studentId,
    String? profileId,
    SupabaseClient? client,
  }) async {
    final normalizedProfileId = profileId?.trim();
    final row = await (client ?? Supabase.instance.client)
        .from('students')
        .update({
          'profile_id':
              normalizedProfileId == null || normalizedProfileId.isEmpty
                  ? null
                  : normalizedProfileId,
        })
        .eq('id', studentId)
        .select(
            'id, profile_id, student_code, first_name, last_name, grade_level, homeroom, active')
        .single();
    final student = Map<String, dynamic>.from(row);
    await _db.cacheAdminStudent(student);
    return student;
  }

  Map<String, dynamic> _validatedAdminStudentValues({
    required String studentCode,
    required String firstName,
    required String lastName,
    required int gradeLevel,
    required String homeroom,
    required bool active,
  }) {
    final normalizedCode = studentCode.trim();
    final normalizedFirstName = firstName.trim();
    final normalizedLastName = lastName.trim();
    final normalizedHomeroom = homeroom.trim();
    if (normalizedCode.isEmpty ||
        normalizedFirstName.isEmpty ||
        normalizedLastName.isEmpty ||
        normalizedHomeroom.isEmpty) {
      throw ArgumentError('Student code, names, and homeroom are required.');
    }
    if (gradeLevel < 9 || gradeLevel > 12) {
      throw ArgumentError('Grade level must be between 9 and 12.');
    }
    return {
      'student_code': normalizedCode,
      'first_name': normalizedFirstName,
      'last_name': normalizedLastName,
      'grade_level': gradeLevel,
      'homeroom': normalizedHomeroom,
      'active': active,
    };
  }

  Future<List<Map<String, dynamic>>> loadAdminEnrollments({
    required String lectureId,
    SupabaseClient? client,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    const pageSize = 500;
    final enrollments = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final rows = await supabase
          .from('enrollments')
          .select('lecture_id, student_id, active')
          .eq('lecture_id', lectureId)
          .range(offset, offset + pageSize - 1);
      enrollments.addAll(rows.map((row) => Map<String, dynamic>.from(row)));
      if (rows.length < pageSize) break;
      offset += pageSize;
    }
    await _db.cacheAdminEnrollments(lectureId, enrollments);
    return enrollments;
  }

  Future<void> setAdminEnrollment({
    required String lectureId,
    required String studentId,
    required bool active,
    SupabaseClient? client,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    if (active) {
      final cachedStudents = await _db.getCachedAdminStudents();
      final hasActiveCachedStudent = cachedStudents.any(
        (student) =>
            student['id'] == studentId &&
            (student['active'] == true || student['active'] == 1),
      );
      if (!hasActiveCachedStudent) {
        throw StateError(
          'Refresh students before enrolling; only active students can be enrolled.',
        );
      }
      await supabase
          .from('enrollments')
          .upsert(
            {
              'lecture_id': lectureId,
              'student_id': studentId,
              'active': true,
            },
            onConflict: 'lecture_id,student_id',
          )
          .select('lecture_id, student_id, active')
          .single();
    } else {
      await supabase
          .from('enrollments')
          .update({'active': false})
          .eq('lecture_id', lectureId)
          .eq('student_id', studentId)
          .select('lecture_id')
          .maybeSingle();
    }
    await _db.cacheAdminEnrollment(
      lectureId: lectureId,
      studentId: studentId,
      active: active,
    );
  }

  Future<List<Lecture>> loadAllLectures({SupabaseClient? client}) async {
    final rows = await (client ?? Supabase.instance.client)
        .from('lectures')
        .select()
        .order('course_code')
        .order('period_number');
    final lectures = rows.map((row) => Lecture.fromMap(row)).toList();
    await _db.cacheLectures(lectures);
    return lectures;
  }

  Future<Lecture> createLectureAssignment({
    required String courseCode,
    required String title,
    required String teacherId,
    required String roomNumber,
    required int periodNumber,
    required String academicTerm,
    SupabaseClient? client,
  }) async {
    final row = await (client ?? Supabase.instance.client)
        .from('lectures')
        .insert({
          'course_code': courseCode.trim(),
          'title': title.trim(),
          'teacher_id': teacherId,
          'room_number': roomNumber.trim(),
          'period_number': periodNumber,
          'academic_term': academicTerm.trim(),
        })
        .select()
        .single();
    final lecture = Lecture.fromMap(row);
    await _cacheLectureAndUpdateState(lecture);
    return lecture;
  }

  Future<Lecture> reassignLectureTeacher({
    required String lectureId,
    required String teacherId,
    SupabaseClient? client,
  }) async {
    final row = await (client ?? Supabase.instance.client)
        .from('lectures')
        .update({'teacher_id': teacherId})
        .eq('id', lectureId)
        .select()
        .single();
    final lecture = Lecture.fromMap(row);
    await _cacheLectureAndUpdateState(lecture);
    return lecture;
  }

  Future<Lecture> updateTeacherLectureTimetable({
    required Lecture lecture,
    required String roomNumber,
    required int periodNumber,
    required String academicTerm,
    required int lateGraceMinutes,
  }) async {
    final userId = _currentUserId();
    if (userId == null) {
      throw StateError('Sign in before updating a lecture timetable.');
    }
    final assignmentError = await validateLectureAssignmentLocally(lecture);
    if (assignmentError != null) throw StateError(assignmentError);
    if (state.activeSession?.lectureId == lecture.id &&
        state.activeSession?.endedAt == null) {
      throw StateError('End the active session before changing the timetable.');
    }
    if (_isLecturePlaceholder(roomNumber) ||
        _isLecturePlaceholder(academicTerm)) {
      throw ArgumentError(
          'Enter a room and academic term to configure the timetable.');
    }
    if (periodNumber < 1 ||
        periodNumber > 32767 ||
        lateGraceMinutes < 0 ||
        lateGraceMinutes > 32767) {
      throw ArgumentError('Enter a valid period and late grace time.');
    }

    final updatedLecture = lecture.copyWith(
      roomNumber: roomNumber.trim(),
      periodNumber: periodNumber,
      academicTerm: academicTerm.trim(),
      lateGraceMinutes: lateGraceMinutes,
    );
    await _db.cachePendingLectureTimetableEdit(updatedLecture);
    _updateLectureInState(updatedLecture);
    if (!await _syncEngine.isOnline()) return updatedLecture;

    try {
      final row = await Supabase.instance.client
          .from('lectures')
          .update({
            'room_number': updatedLecture.roomNumber,
            'period_number': updatedLecture.periodNumber,
            'academic_term': updatedLecture.academicTerm,
            'late_grace_minutes': updatedLecture.lateGraceMinutes,
          })
          .eq('id', lecture.id)
          .eq('teacher_id', userId)
          .select()
          .single();
      final syncedLecture = Lecture.fromMap(row);
      if (syncedLecture.teacherId != userId) {
        throw StateError('The course is no longer assigned to your account.');
      }
      await _db.cacheLectures([syncedLecture]);
      await _db.clearPendingLectureTimetableEdit(syncedLecture.id);
      _updateLectureInState(syncedLecture);
      return syncedLecture;
    } catch (error) {
      throw StateError(
        'Timetable saved on this device, but cloud sync failed: $error',
      );
    }
  }

  Future<void> _cacheLectureAndUpdateState(Lecture lecture) async {
    await _db.cacheLectures([lecture]);
    _updateLectureInState(lecture);
  }

  void _updateLectureInState(Lecture lecture) {
    _setState((current) {
      final isAvailable = current.availableLectures
          .any((availableLecture) => availableLecture.id == lecture.id);
      return current.copyWith(
        activeLecture: current.activeLecture?.id == lecture.id
            ? lecture
            : current.activeLecture,
        availableLectures: isAvailable
            ? current.availableLectures
                .map((availableLecture) => availableLecture.id == lecture.id
                    ? lecture
                    : availableLecture)
                .toList()
            : current.availableLectures,
      );
    });
  }

  Future<void> loadTeacherLectures() async {
    final userId = _currentUserId();
    if (userId == null) {
      throw StateError('Sign in before loading assigned classes.');
    }

    final cachedLectures = (await _db.getCachedLectures(teacherId: userId))
        .where((lecture) => lecture.teacherId == userId)
        .toList();
    // Publish the cache before touching the network so a slow or failed refresh
    // never leaves an offline-capable teacher without their assigned classes.
    if (cachedLectures.isNotEmpty) {
      _setState(
        (current) => current.copyWith(availableLectures: cachedLectures),
      );
    }

    if (!await _syncEngine.isOnline()) {
      _setState(
        (current) => current.copyWith(availableLectures: cachedLectures),
      );
      return;
    }

    // Pending timetable edits have to be uploaded before the cloud copy is
    // fetched, otherwise a failed upload would be overwritten in the cache.
    final syncErrors =
        await _syncEngine.syncPendingLectureTimetableUpdates(userId);
    if (syncErrors.isNotEmpty) throw StateError(syncErrors.join('; '));

    try {
      final rows = await Supabase.instance.client
          .from('lectures')
          .select()
          .eq('teacher_id', userId)
          .order('period_number');
      final lectures = rows
          .map((row) => Lecture.fromMap(row))
          .where((lecture) => lecture.teacherId == userId)
          .toList();
      await _db.cacheLectures(lectures);
      _setState((current) => current.copyWith(availableLectures: lectures));
    } catch (error) {
      if (cachedLectures.isEmpty) rethrow;
      throw StateError(
        'Could not refresh assigned classes; showing the cached copy: $error',
      );
    }
  }

  Future<String?> validateLectureLocally(Lecture? lecture) async {
    final assignmentError = await validateLectureAssignmentLocally(lecture);
    if (assignmentError != null) return assignmentError;
    final cached = await _db.getCachedLecture(lecture!.id);
    if (_isLecturePlaceholder(cached!.roomNumber) ||
        cached.periodNumber < 1 ||
        cached.periodNumber > 32767 ||
        _isLecturePlaceholder(cached.academicTerm)) {
      return 'Configure this course timetable on your device before starting attendance.';
    }
    return null;
  }

  Future<String?> validateLectureAssignmentLocally(Lecture? lecture) async {
    if (lecture == null) return 'Choose an assigned course first.';
    final userId = _currentUserId();
    if (userId == null) return 'Sign in before starting attendance.';
    if (lecture.teacherId != userId) {
      return 'This course is not assigned to your account. Contact an admin.';
    }

    final cached = await _db.getCachedLecture(lecture.id);
    if (cached == null) {
      return 'This course is not available in the local cache. Refresh your courses.';
    }
    if (cached.teacherId != userId) {
      return 'The cached course is assigned to another lecturer. Refresh your courses.';
    }
    if (cached.teacherId != lecture.teacherId ||
        cached.courseCode != lecture.courseCode ||
        cached.title != lecture.title ||
        cached.roomNumber != lecture.roomNumber ||
        cached.periodNumber != lecture.periodNumber ||
        cached.academicTerm != lecture.academicTerm ||
        cached.lateGraceMinutes != lecture.lateGraceMinutes) {
      return 'This course differs from its local cached record. Refresh and select it again.';
    }
    if (cached.id.trim().isEmpty ||
        cached.courseCode.trim().isEmpty ||
        cached.title.trim().isEmpty ||
        cached.teacherId.trim().isEmpty ||
        cached.periodNumber < 1 ||
        cached.periodNumber > 32767 ||
        cached.lateGraceMinutes < 0 ||
        cached.lateGraceMinutes > 32767) {
      return 'This course has incomplete details. Contact an admin.';
    }
    return null;
  }

  bool _isLecturePlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isEmpty ||
        const {
          'tbd',
          'to be determined',
          'unassigned',
          'unknown',
          'n/a',
          'na',
          '-',
        }.contains(normalized);
  }

  Future<String?> validateStartSessionLocally() async {
    final lecture = state.activeLecture;
    if (lecture == null) return 'Choose an assigned course first.';
    final lectureError = await validateLectureLocally(lecture);
    if (lectureError != null) return lectureError;
    if (state.roster.isEmpty) {
      return 'This course has no cached student roster. Refresh the course roster before starting.';
    }

    final userId = _currentUserId();
    if (userId == null) return 'Sign in before starting attendance.';
    final today = localSessionDate(DateTime.now());
    final sessions = await _db.getSessionsForTeacherOnDate(userId, today);
    if (sessions.any((session) =>
        session.endedAt == null && session.lectureId != lecture.id)) {
      return 'Another course already has an active session today. End it before starting this course.';
    }
    final existingCourseSession = sessions.where(
      (session) => session.lectureId == lecture.id,
    );
    if (existingCourseSession.any((session) => session.endedAt != null)) {
      return 'Attendance for this course has already ended today.';
    }
    return null;
  }

  Future<String?> validatePassModeLaunchLocally() async {
    final session = state.activeSession;
    if (session == null || session.endedAt != null) {
      return 'Start an attendance session before launching Pass Mode.';
    }
    final lecture = state.activeLecture;
    if (lecture == null) return 'Choose an assigned course first.';
    final lectureError = await validateLectureLocally(lecture);
    if (lectureError != null) return lectureError;
    final userId = _currentUserId();
    if (userId == null) return 'Sign in before launching Pass Mode.';
    if (session.teacherId != userId ||
        session.lectureId != lecture.id ||
        session.sessionDate != localSessionDate(DateTime.now())) {
      return 'This session does not match your assigned course or today’s date. Select the assigned course and start a new session.';
    }
    final sessions = await _db.getSessionsForTeacherOnDate(
      userId,
      session.sessionDate,
    );
    if (sessions.any(
      (other) => other.endedAt == null && other.id != session.id,
    )) {
      return 'Another course already has an active session today. End it before launching Pass Mode.';
    }
    return null;
  }

  Future<List<Student>> loadLectureRoster(Lecture lecture) async {
    final validationError = await validateLectureAssignmentLocally(lecture);
    if (validationError != null) throw StateError(validationError);
    if (await _syncEngine.isOnline()) {
      final rows = await Supabase.instance.client
          .from('enrollments')
          .select(
              'students!inner(id, student_code, first_name, last_name, grade_level, homeroom, active)')
          .eq('lecture_id', lecture.id)
          .eq('active', true)
          .eq('students.active', true);
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

  Future<void> selectLecture(Lecture lecture, List<Student> students) async {
    if (state.activeSession?.endedAt == null && state.activeSession != null) {
      throw StateError('End the active session before changing classes.');
    }
    final validationError = await validateLectureAssignmentLocally(lecture);
    if (validationError != null) throw StateError(validationError);
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
    if (state.activeLecture?.id != lecture.id) {
      throw StateError(
          'Choose this assigned course before starting a session.');
    }
    final validationError = await validateStartSessionLocally();
    if (validationError != null) throw StateError(validationError);
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
    final session = await _db.createSessionIfAbsent(
      proposedSession,
      rejectTeacherDateConflict: true,
    );
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

  Future<void> lockPassMode() async {
    final validationError = await validatePassModeLaunchLocally();
    if (validationError != null) throw StateError(validationError);
    await _setPassModeLocked(true);
  }

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
    if (session.endedAt != null) {
      return const BiometricVerificationResult(
        verified: false,
        method: 'ended',
        errorMessage: 'This attendance session has already ended.',
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
    if (requiresReason &&
        (normalizedReason == null || normalizedReason.isEmpty)) {
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
