import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/widgets/startup_error_app.dart';

void main() {
  testWidgets('reports the startup exception and retries on demand',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      StartupErrorApp(
        error: StateError('keystore unavailable'),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('LectureGuard could not start'), findsOneWidget);
    expect(
      find.textContaining('keystore unavailable'),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('omits the retry action when no callback is provided',
      (tester) async {
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));

    expect(find.text('Retry'), findsNothing);
    expect(find.text('Copy details'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
