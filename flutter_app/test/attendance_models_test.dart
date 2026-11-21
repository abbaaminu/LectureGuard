import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';

void main() {
  test(
      'student map round-trip preserves profile fields and normalizes initials',
      () {
    const student = Student(
      id: 'student-1',
      studentCode: 'STU-1',
      firstName: 'Élodie',
      lastName: 'Álvarez',
      gradeLevel: 11,
      homeroom: '11A',
    );

    final restored = Student.fromMap(student.toMap());

    expect(restored.id, student.id);
    expect(restored.firstName, student.firstName);
    expect(restored.sortInitial, 'A');
    expect(
      const Student(
        id: 'student-2',
        studentCode: 'STU-2',
        firstName: 'Unknown',
        lastName: '123 Smith',
        gradeLevel: 9,
        homeroom: '9A',
      ).sortInitial,
      '#',
    );
  });

  test('attendance record SQLite map preserves sync and override metadata', () {
    final record = AttendanceRecord(
      id: 'record-1',
      sessionId: 'session-1',
      lectureId: 'lecture-1',
      studentId: 'student-1',
      status: AttendanceStatus.late,
      checkedInAt: DateTime(2026, 11, 20, 9, 15),
      biometricVerified: true,
      biometricMethod: 'face',
      overrideReason: 'Teacher corrected status',
      overrideBy: 'teacher-1',
      syncStatus: SyncStatus.failed,
      deviceRecordedAt: DateTime(2026, 11, 20, 9, 15),
      rowVersion: 7,
      attemptCount: 2,
    );

    final restored = AttendanceRecord.fromMap(record.toSqliteMap());

    expect(restored.status, AttendanceStatus.late);
    expect(restored.syncStatus, SyncStatus.failed);
    expect(restored.overrideBy, 'teacher-1');
    expect(restored.overrideReason, 'Teacher corrected status');
    expect(restored.rowVersion, 7);
    expect(restored.attemptCount, 2);
    expect(restored.isLocked, isTrue);
    expect(
        restored.toSupabasePayload(), containsPair('override_by', 'teacher-1'));
  });

  test('school setting reads SQLite and Supabase boolean representations', () {
    expect(
      SchoolSettings.fromMap({'excused_counts_as_attended': 0})
          .excusedCountsAsAttended,
      isFalse,
    );
    expect(
      SchoolSettings.fromMap({'excused_counts_as_attended': true})
          .excusedCountsAsAttended,
      isTrue,
    );
  });
}
