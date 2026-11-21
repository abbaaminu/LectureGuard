import 'package:diacritic/diacritic.dart';
import '../models/attendance_models.dart';

const rosterAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

String normalizeRosterSearch(String value) =>
    removeDiacritics(value).toLowerCase().trim();

List<Student> sortStudents(Iterable<Student> students) {
  final sorted = students.toList();
  sorted.sort((a, b) {
    final aInitial = a.sortInitial;
    final bInitial = b.sortInitial;
    if (aInitial == '#' && bInitial != '#') return 1;
    if (bInitial == '#' && aInitial != '#') return -1;

    final lastName = normalizeRosterSearch(a.lastName)
        .compareTo(normalizeRosterSearch(b.lastName));
    if (lastName != 0) return lastName;
    final firstName = normalizeRosterSearch(a.firstName)
        .compareTo(normalizeRosterSearch(b.firstName));
    if (firstName != 0) return firstName;
    return normalizeRosterSearch(a.studentCode)
        .compareTo(normalizeRosterSearch(b.studentCode));
  });
  return sorted;
}

Map<String, int> buildRosterLetterIndex(List<Student> roster) {
  final index = <String, int>{};
  for (var position = 0; position < roster.length; position++) {
    final initial = roster[position].sortInitial;
    if (initial != '#') index.putIfAbsent(initial, () => position);
  }
  return index;
}

String? nextAvailableLetter(String requested, Map<String, int> letterIndex) {
  final start = rosterAlphabet.indexOf(requested.toUpperCase());
  if (start < 0) return null;
  for (var position = start; position < rosterAlphabet.length; position++) {
    final letter = rosterAlphabet[position];
    if (letterIndex.containsKey(letter)) return letter;
  }
  // Nothing at or after the requested letter: walk backwards so a tap near the
  // end of the alphabet (for example "Z" on a roster whose last name starts
  // with "M") still lands on the nearest previous section instead of doing
  // nothing.
  for (var position = start - 1; position >= 0; position--) {
    final letter = rosterAlphabet[position];
    if (letterIndex.containsKey(letter)) return letter;
  }
  return null;
}
