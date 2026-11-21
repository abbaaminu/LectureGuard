import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/services/student_roster.dart';

void main() {
  const students = [
    Student(
      id: 'z',
      studentCode: 'Z',
      firstName: 'Zoë',
      lastName: 'Zulu',
      gradeLevel: 10,
      homeroom: '10A',
    ),
    Student(
      id: 'e',
      studentCode: 'E',
      firstName: 'Élodie',
      lastName: 'Éclair',
      gradeLevel: 10,
      homeroom: '10A',
    ),
    Student(
      id: 'a',
      studentCode: 'A',
      firstName: 'Amir',
      lastName: 'Álvarez',
      gradeLevel: 10,
      homeroom: '10A',
    ),
    Student(
      id: 'other',
      studentCode: 'O',
      firstName: 'Number',
      lastName: '9Smith',
      gradeLevel: 10,
      homeroom: '10A',
    ),
  ];

  test('sorts names with diacritic-insensitive last and first names', () {
    expect(sortStudents(students).map((student) => student.id),
        ['a', 'e', 'z', 'other']);
  });

  test('search normalization matches accented text with plain characters', () {
    expect(normalizeRosterSearch('Élodie'), 'elodie');
    expect(normalizeRosterSearch('ALVAREZ'), 'alvarez');
  });

  test('initial index uses base letters and skips unavailable letters', () {
    final sorted = sortStudents(students);
    final index = buildRosterLetterIndex(sorted);

    expect(index.keys, containsAll(['A', 'E', 'Z']));
    expect(sorted.last.sortInitial, '#');
    expect(nextAvailableLetter('B', index), 'E');
    expect(nextAvailableLetter('Y', index), 'Z');
    expect(nextAvailableLetter('Z', index), 'Z');
  });

  test('A-Z bar falls back to the nearest previous letter', () {
    // Regression: a tap past the last available letter used to do nothing.
    expect(nextAvailableLetter('Z', {'A': 0, 'E': 3}), 'E');
    expect(nextAvailableLetter('Z', {'A': 0}), 'A');
    expect(nextAvailableLetter('M', {'A': 0, 'E': 3}), 'E');
    expect(nextAvailableLetter('Z', const {}), isNull);
    expect(nextAvailableLetter('1', {'A': 0}), isNull);
  });
}
