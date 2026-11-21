import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/models/attendance_models.dart';
import 'package:lecture_guard/widgets/teacher_override_dialog.dart';

void main() {
  testWidgets('requires a reason for absent and saves the selected override',
      (tester) async {
    TeacherOverrideRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<TeacherOverrideRequest>(
                  context: context,
                  builder: (_) => const TeacherOverrideDialog(
                    studentName: 'Amina Bello',
                    initialStatus: AttendanceStatus.present,
                    overridingBiometricCheckIn: false,
                  ),
                );
              },
              child: const Text('Open override'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open override'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Absent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a reason to continue.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Medical leave');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.status, AttendanceStatus.absent);
    expect(result?.reason, 'Medical leave');
  });

  testWidgets('biometric check-in overrides require a reason', (tester) async {
    TeacherOverrideRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<TeacherOverrideRequest>(
                  context: context,
                  builder: (_) => const TeacherOverrideDialog(
                    studentName: 'Amina Bello',
                    initialStatus: AttendanceStatus.present,
                    overridingBiometricCheckIn: true,
                  ),
                );
              },
              child: const Text('Open override'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open override'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a reason to continue.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Corrected by teacher');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.status, AttendanceStatus.present);
    expect(result?.reason, 'Corrected by teacher');
  });

  testWidgets('excused overrides require a reason', (tester) async {
    TeacherOverrideRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<TeacherOverrideRequest>(
                  context: context,
                  builder: (_) => const TeacherOverrideDialog(
                    studentName: 'Amina Bello',
                    initialStatus: AttendanceStatus.present,
                    overridingBiometricCheckIn: false,
                  ),
                );
              },
              child: const Text('Open override'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open override'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excused'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a reason to continue.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Approved absence');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.status, AttendanceStatus.excused);
    expect(result?.reason, 'Approved absence');
  });
}
