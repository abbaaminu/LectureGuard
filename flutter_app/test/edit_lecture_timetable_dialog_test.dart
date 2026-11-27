import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/screens/edit_lecture_timetable_dialog.dart';

void main() {
  testWidgets('saves timetable fields without exposing course identity',
      (tester) async {
    const lecture = Lecture(
      id: 'lecture-1',
      courseCode: 'BIO-101',
      title: 'Biology',
      teacherId: 'teacher-1',
      teacherName: 'Teacher',
      roomNumber: 'TBD',
      periodNumber: 1,
      academicTerm: '2026-T2',
    );
    LectureTimetableUpdate? update;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                update = await showDialog<LectureTimetableUpdate>(
                  context: context,
                  builder: (_) =>
                      const EditLectureTimetableDialog(lecture: lecture),
                );
              },
              child: const Text('Open timetable'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open timetable'));
    await tester.pumpAndSettle();
    expect(find.text('BIO-101 · Biology'), findsOneWidget);
    expect(find.text('Course code'), findsNothing);

    await tester.enterText(find.byType(TextFormField).at(0), 'Room B2');
    await tester.enterText(find.byType(TextFormField).at(1), '4');
    await tester.enterText(find.byType(TextFormField).at(2), '2027-T1');
    await tester.enterText(find.byType(TextFormField).at(3), '15');
    await tester.tap(find.text('Save timetable'));
    await tester.pumpAndSettle();

    expect(update?.roomNumber, 'Room B2');
    expect(update?.periodNumber, 4);
    expect(update?.academicTerm, '2027-T1');
    expect(update?.lateGraceMinutes, 15);
  });

  testWidgets('rejects a period outside the database SMALLINT range',
      (tester) async {
    const lecture = Lecture(
      id: 'lecture-1',
      courseCode: 'BIO-101',
      title: 'Biology',
      teacherId: 'teacher-1',
      teacherName: 'Teacher',
      roomNumber: 'A1',
      periodNumber: 1,
      academicTerm: '2026-T2',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<LectureTimetableUpdate>(
                context: context,
                builder: (_) =>
                    const EditLectureTimetableDialog(lecture: lecture),
              ),
              child: const Text('Open timetable'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open timetable'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Room B2');
    await tester.enterText(find.byType(TextFormField).at(1), '32768');
    await tester.enterText(find.byType(TextFormField).at(2), '2027-T1');
    await tester.enterText(find.byType(TextFormField).at(3), '15');
    await tester.tap(find.text('Save timetable'));
    await tester.pumpAndSettle();

    expect(
      find.text('period number must be 32767 or less.'),
      findsOneWidget,
    );
    expect(find.byType(EditLectureTimetableDialog), findsOneWidget);
  });
}
