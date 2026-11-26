import 'package:diacritic/diacritic.dart';

enum AttendanceStatus { present, late, absent, excused }

enum SyncStatus { pending, synced, failed }

enum UserRole { admin, teacher, student }

/// Maps a `profiles.role` value to a [UserRole] without throwing.
///
/// `UserRole.values.byName` raises an [ArgumentError] for anything it does not
/// know, and that exception used to escape the sign-in flow and strand the user
/// on the "could not load your school profile" screen whenever the database
/// carried a role the shipped build predates (for example a role added by a
/// newer migration). Unknown or missing values return `null`, which the access
/// gate already renders as "no profile".
UserRole? userRoleFromName(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  for (final role in UserRole.values) {
    if (role.name == normalized) return role;
  }
  return null;
}

class Student {
  final String id;
  final String studentCode;
  final String firstName;
  final String lastName;
  final int gradeLevel;
  final String homeroom;

  const Student({
    required this.id,
    required this.studentCode,
    required this.firstName,
    required this.lastName,
    required this.gradeLevel,
    required this.homeroom,
  });

  String get fullName => '$lastName, $firstName';
  String get displayName => '$firstName $lastName';
  String get sortInitial {
    final trimmed = lastName.trimLeft();
    if (trimmed.isEmpty) return '#';
    final initial = removeDiacritics(trimmed[0]).toUpperCase();
    return RegExp(r'^[A-Z]$').hasMatch(initial) ? initial : '#';
  }

  factory Student.fromMap(Map<String, dynamic> map) => Student(
        id: map['id'] as String,
        studentCode: map['student_code'] as String,
        firstName: map['first_name'] as String,
        lastName: map['last_name'] as String,
        gradeLevel: map['grade_level'] as int,
        homeroom: map['homeroom'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'student_code': studentCode,
        'first_name': firstName,
        'last_name': lastName,
        'grade_level': gradeLevel,
        'homeroom': homeroom,
      };
}

class Lecture {
  final String id;
  final String courseCode;
  final String title;
  final String teacherId;
  final String teacherName;
  final String roomNumber;
  final int periodNumber;
  final int lateGraceMinutes;

  const Lecture({
    required this.id,
    required this.courseCode,
    required this.title,
    required this.teacherId,
    required this.teacherName,
    required this.roomNumber,
    required this.periodNumber,
    this.lateGraceMinutes = 10,
  });

  factory Lecture.fromMap(Map<String, dynamic> map) => Lecture(
        id: map['id'] as String,
        courseCode: map['course_code'] as String,
        title: map['title'] as String,
        teacherId: map['teacher_id'] as String,
        teacherName: (map['teacher_name'] as String?) ?? 'Faculty',
        roomNumber: map['room_number'] as String,
        periodNumber: map['period_number'] as int,
        lateGraceMinutes: (map['late_grace_minutes'] as int?) ?? 10,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'course_code': courseCode,
        'title': title,
        'teacher_id': teacherId,
        'teacher_name': teacherName,
        'room_number': roomNumber,
        'period_number': periodNumber,
        'late_grace_minutes': lateGraceMinutes,
      };
}

class AttendanceSession {
  final String id;
  final String lectureId;
  final String teacherId;
  final String deviceId;
  final String sessionDate;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool isLockedPassMode;
  final int enrolledCount;

  const AttendanceSession({
    required this.id,
    required this.lectureId,
    required this.teacherId,
    required this.deviceId,
    required this.sessionDate,
    required this.startedAt,
    this.endedAt,
    this.isLockedPassMode = true,
    required this.enrolledCount,
  });

  AttendanceSession copyWith({
    DateTime? endedAt,
    bool? isLockedPassMode,
  }) =>
      AttendanceSession(
        id: id,
        lectureId: lectureId,
        teacherId: teacherId,
        deviceId: deviceId,
        sessionDate: sessionDate,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        isLockedPassMode: isLockedPassMode ?? this.isLockedPassMode,
        enrolledCount: enrolledCount,
      );

  factory AttendanceSession.fromMap(Map<String, dynamic> map) {
    final startedAt = DateTime.parse(map['started_at'] as String);
    final sessionDate = map['session_date'] as String?;
    return AttendanceSession(
      id: map['id'] as String,
      lectureId: map['lecture_id'] as String,
      teacherId: map['teacher_id'] as String,
      deviceId: map['device_id'] as String,
      sessionDate: sessionDate == null || sessionDate.isEmpty
          ? '${startedAt.year.toString().padLeft(4, '0')}-'
              '${startedAt.month.toString().padLeft(2, '0')}-'
              '${startedAt.day.toString().padLeft(2, '0')}'
          : sessionDate,
      startedAt: startedAt,
      endedAt: map['ended_at'] == null
          ? null
          : DateTime.parse(map['ended_at'] as String),
      isLockedPassMode: (map['is_locked_pass_mode'] as int) == 1,
      enrolledCount: map['enrolled_count'] as int,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'lecture_id': lectureId,
        'teacher_id': teacherId,
        'device_id': deviceId,
        'session_date': sessionDate,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'is_locked_pass_mode': isLockedPassMode ? 1 : 0,
        'enrolled_count': enrolledCount,
      };

  Map<String, dynamic> toSupabasePayload() => {
        'id': id,
        'lecture_id': lectureId,
        'teacher_id': teacherId,
        'device_id': deviceId,
        'session_date': sessionDate,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'state': endedAt != null
            ? 'completed'
            : isLockedPassMode
                ? 'locked_pass_mode'
                : 'active',
        'enrolled_snapshot_count': enrolledCount,
      };
}

class AttendanceRecord {
  final String id;
  final String sessionId;
  final String lectureId;
  final String studentId;
  final AttendanceStatus status;
  final DateTime? checkedInAt;
  final bool biometricVerified;
  final String? biometricMethod;
  final String? overrideReason;
  final String? overrideBy;
  final SyncStatus syncStatus;
  final DateTime deviceRecordedAt;
  final int rowVersion;
  final int attemptCount;

  const AttendanceRecord({
    required this.id,
    required this.sessionId,
    required this.lectureId,
    required this.studentId,
    required this.status,
    this.checkedInAt,
    this.biometricVerified = false,
    this.biometricMethod,
    this.overrideReason,
    this.overrideBy,
    this.syncStatus = SyncStatus.pending,
    required this.deviceRecordedAt,
    this.rowVersion = 1,
    this.attemptCount = 0,
  });

  bool get isLocked =>
      biometricVerified &&
      (status == AttendanceStatus.present || status == AttendanceStatus.late);

  AttendanceRecord copyWith({
    AttendanceStatus? status,
    DateTime? checkedInAt,
    bool? biometricVerified,
    String? biometricMethod,
    String? overrideReason,
    String? overrideBy,
    SyncStatus? syncStatus,
    DateTime? deviceRecordedAt,
    int? rowVersion,
    int? attemptCount,
  }) =>
      AttendanceRecord(
        id: id,
        sessionId: sessionId,
        lectureId: lectureId,
        studentId: studentId,
        status: status ?? this.status,
        checkedInAt: checkedInAt ?? this.checkedInAt,
        biometricVerified: biometricVerified ?? this.biometricVerified,
        biometricMethod: biometricMethod ?? this.biometricMethod,
        overrideReason: overrideReason ?? this.overrideReason,
        overrideBy: overrideBy ?? this.overrideBy,
        syncStatus: syncStatus ?? this.syncStatus,
        deviceRecordedAt: deviceRecordedAt ?? this.deviceRecordedAt,
        rowVersion: rowVersion ?? this.rowVersion,
        attemptCount: attemptCount ?? this.attemptCount,
      );

  factory AttendanceRecord.fromMap(Map<String, dynamic> map) =>
      AttendanceRecord(
        id: map['id'] as String,
        sessionId: map['session_id'] as String,
        lectureId: map['lecture_id'] as String,
        studentId: map['student_id'] as String,
        status: AttendanceStatus.values.byName(map['status'] as String),
        checkedInAt: map['checked_in_at'] != null
            ? DateTime.parse(map['checked_in_at'] as String)
            : null,
        biometricVerified: (map['biometric_verified'] as int) == 1,
        biometricMethod: map['biometric_method'] as String?,
        overrideReason: map['override_reason'] as String?,
        overrideBy: map['override_by'] as String?,
        syncStatus: SyncStatus.values.byName(map['sync_status'] as String),
        deviceRecordedAt: DateTime.parse(map['device_recorded_at'] as String),
        rowVersion: (map['row_version'] as int?) ?? 1,
        attemptCount: (map['attempt_count'] as int?) ?? 0,
      );

  Map<String, dynamic> toSqliteMap() => {
        'id': id,
        'session_id': sessionId,
        'lecture_id': lectureId,
        'student_id': studentId,
        'status': status.name,
        'checked_in_at': checkedInAt?.toIso8601String(),
        'biometric_verified': biometricVerified ? 1 : 0,
        'biometric_method': biometricMethod,
        'override_reason': overrideReason,
        'override_by': overrideBy,
        'sync_status': syncStatus.name,
        'device_recorded_at': deviceRecordedAt.toIso8601String(),
        'row_version': rowVersion,
        'attempt_count': attemptCount,
      };

  Map<String, dynamic> toSupabasePayload() => {
        // Send the deterministic id (session id + student id) so a retried or
        // duplicated check-in maps onto the same cloud row instead of relying on
        // whichever id the database happened to assign first. The sync engine
        // upserts on this column.
        'id': id,
        'session_id': sessionId,
        'lecture_id': lectureId,
        'student_id': studentId,
        'status': status.name,
        'checked_in_at': checkedInAt?.toIso8601String(),
        'biometric_verified': biometricVerified,
        'biometric_method': biometricMethod,
        'override_reason': overrideReason,
        'override_by': overrideBy,
        'device_recorded_at': deviceRecordedAt.toIso8601String(),
      };
}

class SchoolSettings {
  final bool excusedCountsAsAttended;

  const SchoolSettings({this.excusedCountsAsAttended = false});

  factory SchoolSettings.fromMap(Map<String, dynamic> map) => SchoolSettings(
        excusedCountsAsAttended: map['excused_counts_as_attended'] == true ||
            map['excused_counts_as_attended'] == 1,
      );

  Map<String, Object> toSqliteMap() => {
        'id': 1,
        'excused_counts_as_attended': excusedCountsAsAttended ? 1 : 0,
      };

  Map<String, Object> toSupabasePayload() => {
        'excused_counts_as_attended': excusedCountsAsAttended,
      };
}
