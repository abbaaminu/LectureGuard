import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/main.dart';

void main() {
  group('runGuardedStartup', () {
    test('shows the app when every startup step succeeds', () async {
      var appShown = false;
      Object? reported;

      await runGuardedStartup(
        initialize: () async {},
        showApplication: () => appShown = true,
        showError: (error) => reported = error,
      );

      expect(appShown, isTrue);
      expect(reported, isNull);
    });

    test('reports a throwing step instead of letting it kill the process',
        () async {
      final failure = StateError(
        'Failed to create an instance of class '
        'androidx.work.impl.WorkDatabase',
      );
      var appShown = false;
      Object? reported;

      await runGuardedStartup(
        initialize: () async => throw failure,
        showApplication: () => appShown = true,
        showError: (error) => reported = error,
      );

      expect(appShown, isFalse,
          reason: 'a half-initialised app must not be shown');
      expect(reported, same(failure));
    });
  });

  group('initializeStartupServices', () {
    test('initialises Supabase before registering the background worker',
        () async {
      final order = <String>[];

      await initializeStartupServices(
        initializeSupabase: () async => order.add('supabase'),
        registerBackgroundSync: () async => order.add('sync'),
      );

      expect(order, ['supabase', 'sync']);
    });

    test('does not register the worker when Supabase fails', () async {
      var registered = false;

      await expectLater(
        initializeStartupServices(
          initializeSupabase: () async => throw StateError('bad key'),
          registerBackgroundSync: () async => registered = true,
        ),
        throwsStateError,
      );
      expect(registered, isFalse);
    });

    test('a hung step is reported as a TimeoutException for the guard',
        () async {
      final never = Completer<void>();

      await expectLater(
        initializeStartupServices(
          initializeSupabase: () => never.future,
          registerBackgroundSync: () async {},
          stepTimeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('Supabase initialisation'),
          ),
        ),
      );
    });
  });
}
