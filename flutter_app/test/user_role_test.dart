import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';

void main() {
  test('known role names map to their enum value', () {
    expect(userRoleFromName('admin'), UserRole.admin);
    expect(userRoleFromName('teacher'), UserRole.teacher);
    expect(userRoleFromName('student'), UserRole.student);
  });

  test('unknown role names map to null instead of throwing', () {
    // A profile row can carry a role the shipped build predates (for example a
    // role added by a newer migration). It must fall through to the access
    // message, not crash the sign-in flow.
    expect(userRoleFromName('principal'), isNull);
    expect(userRoleFromName('TEACHER-ASSISTANT'), isNull);
  });

  test('missing or blank role values map to null', () {
    expect(userRoleFromName(null), isNull);
    expect(userRoleFromName(''), isNull);
    expect(userRoleFromName('   '), isNull);
  });

  test('role names tolerate casing and surrounding whitespace', () {
    expect(userRoleFromName(' Teacher '), UserRole.teacher);
    expect(userRoleFromName('ADMIN'), UserRole.admin);
  });
}
