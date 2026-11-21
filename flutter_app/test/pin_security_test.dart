import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/screens/lecturer_pin_setup_screen.dart';
import 'package:lecture_guard/screens/student_pass_mode_screen.dart';
import 'package:lecture_guard/services/pin_security_service.dart';
import 'package:lecture_guard/widgets/pin_exit_dialog.dart';

void main() {
  late _MemoryPinSecretStore store;
  late DateTime now;

  setUp(() {
    store = _MemoryPinSecretStore();
    now = DateTime.utc(2026, 1, 1);
  });

  PinSecurityService pinService() => PinSecurityService(
        storage: store,
        clock: () => now,
        hashFunction: _fastTestHash,
      );

  test('stores a 256-bit PBKDF2 hash using at least 100k iterations', () async {
    final service = PinSecurityService(
      storage: store,
      clock: () => now,
    );
    await service.setLecturerPin('5729');

    expect(await store.read('lg_lecturer_pin_iterations'), '100000');
    expect(
      base64Url.decode((await store.read('lg_lecturer_pin_hash'))!).length,
      32,
    );
    expect(await service.verifyLecturerPin('5729'), isTrue);
  });

  test('fresh install has no PIN until setup and rejects weak PINs', () async {
    final service = pinService();

    expect(await service.ensurePinInitialized(), isFalse);
    await expectLater(
      service.verifyLecturerPin('6041'),
      throwsA(isA<StateError>()),
    );
    expect(PinSecurityService.validatePin('0000'), isNotNull);
    expect(PinSecurityService.validatePin('1234'), isNotNull);
    expect(PinSecurityService.validatePin('8888'), isNotNull);
  });

  test('PIN changes require the old PIN and rotate the salt', () async {
    final service = pinService();
    await service.setLecturerPin('5729');
    final firstSalt = await store.read('lg_lecturer_pin_salt');
    await expectLater(
      service.setLecturerPin('7392'),
      throwsA(isA<StateError>()),
    );

    expect(
      await service.changeLecturerPin(oldPin: '1111', newPin: '7392'),
      isFalse,
    );
    expect(await service.verifyLecturerPin('5729'), isTrue);
    expect(
      await service.changeLecturerPin(oldPin: '5729', newPin: '7392'),
      isTrue,
    );
    expect(await service.verifyLecturerPin('5729'), isFalse);
    expect(await service.verifyLecturerPin('7392'), isTrue);
    expect(await store.read('lg_lecturer_pin_salt'), isNot(firstSalt));
  });

  testWidgets('PIN setup rejects 1234 and repeated digits', (tester) async {
    final service = pinService();
    await tester.pumpWidget(
      MaterialApp(home: LecturerPinSetupScreen(pinService: service)),
    );

    await tester.enterText(find.byKey(const Key('pin-setup-new')), '1234');
    await tester.enterText(find.byKey(const Key('pin-setup-confirm')), '1234');
    await tester.tap(find.byKey(const Key('pin-setup-save')));
    await tester.pump();
    expect(find.textContaining('less predictable'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pin-setup-new')), '0000');
    await tester.enterText(find.byKey(const Key('pin-setup-confirm')), '0000');
    await tester.tap(find.byKey(const Key('pin-setup-save')));
    await tester.pump();
    expect(find.textContaining('less predictable'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pin-setup-new')), '7777');
    await tester.enterText(find.byKey(const Key('pin-setup-confirm')), '7777');
    await tester.tap(find.byKey(const Key('pin-setup-save')));
    await tester.pump();
    expect(find.textContaining('less predictable'), findsOneWidget);
    expect(await service.ensurePinInitialized(), isFalse);
  });

  testWidgets('PIN setup rejects mismatched entries', (tester) async {
    final service = pinService();
    await tester.pumpWidget(
      MaterialApp(home: LecturerPinSetupScreen(pinService: service)),
    );

    await tester.enterText(find.byKey(const Key('pin-setup-new')), '5729');
    await tester.enterText(find.byKey(const Key('pin-setup-confirm')), '5728');
    await tester.tap(find.byKey(const Key('pin-setup-save')));
    await tester.pump();

    expect(find.text('The PIN entries do not match.'), findsOneWidget);
    expect(await service.ensurePinInitialized(), isFalse);
  });

  testWidgets('PIN lockout countdown persists and expires', (tester) async {
    final service = pinService();
    await service.setLecturerPin('5729');
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(await service.verifyLecturerPin('1111'), isFalse);
    }

    final restoredService = pinService();
    expect(
      (await restoredService.getLockoutStatus()).remaining,
      const Duration(seconds: 30),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLecturerPinVerificationDialog(
                context: context,
                pinService: restoredService,
              ),
              child: const Text('Open PIN dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open PIN dialog'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('PIN locked for 30 seconds.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(
              const Key('lecturer-pin-submit'),
            ))
            .onPressed,
        isNull);

    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('pin-lockout-countdown')), findsNothing);
  });

  test('PIN lockout doubles after a later set of five failures', () async {
    final service = pinService();
    await service.setLecturerPin('5729');
    for (var attempt = 0; attempt < 5; attempt++) {
      await service.verifyLecturerPin('1111');
    }
    now = now.add(const Duration(seconds: 31));
    for (var attempt = 0; attempt < 5; attempt++) {
      await service.verifyLecturerPin('1111');
    }

    expect(
      (await service.getLockoutStatus()).remaining,
      const Duration(seconds: 60),
    );
  });

  test('PIN lockout backoff stops growing at one hour', () async {
    final service = pinService();
    await service.setLecturerPin('5729');

    // Twelve rounds of five failures would be 30s * 2^11 (~17 hours) without a
    // cap, and the stored level keeps growing from there.
    for (var round = 0; round < 12; round++) {
      if (round > 0) {
        now = now.add(const Duration(hours: 2));
      }
      for (var attempt = 0; attempt < 5; attempt++) {
        await service.verifyLecturerPin('1111');
      }
    }

    expect(
      (await service.getLockoutStatus()).remaining,
      const Duration(hours: 1),
    );
  });

  test('a corrupted lockout level cannot overflow the backoff', () async {
    final service = pinService();
    await service.setLecturerPin('5729');
    for (var attempt = 0; attempt < 5; attempt++) {
      await service.verifyLecturerPin('1111');
    }
    // Level 99 would shift far past the integer width on the web.
    await store.write('lg_lecturer_pin_lockout_level', '99');
    now = now.add(const Duration(hours: 2));
    for (var attempt = 0; attempt < 5; attempt++) {
      await service.verifyLecturerPin('1111');
    }

    final remaining = (await service.getLockoutStatus()).remaining;
    expect(remaining, const Duration(hours: 1));
  });

  testWidgets('Pass Mode blocks route pop and invokes the PIN gate',
      (tester) async {
    var blockedPopAttempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PassModePopGuard(
                    canPop: false,
                    onBlockedPop: () async {
                      blockedPopAttempts++;
                    },
                    child: const Scaffold(
                      key: Key('student-pass-mode-screen'),
                      body: Text('Pass Mode'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open Pass Mode'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Pass Mode'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(
      find.byKey(const Key('student-pass-mode-screen')),
      findsOneWidget,
    );
    expect(blockedPopAttempts, 1);
  });

  testWidgets('the exit dialog locks out after five wrong PINs and unlocks later',
      (tester) async {
    final service = pinService();
    await service.setLecturerPin('5729');
    bool? verified;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                verified = await showAdminPinExitDialog(
                  context: context,
                  pinService: service,
                );
              },
              child: const Text('Exit Pass Mode'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Exit Pass Mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);

    for (var attempt = 0; attempt < 5; attempt++) {
      await tester.enterText(
        find.byKey(const Key('lecturer-pin-input')),
        '1111',
      );
      await tester.tap(find.byKey(const Key('lecturer-pin-submit')));
      await tester.pump();
      await tester.pump();
    }

    expect(find.textContaining('Too many attempts'), findsOneWidget);
    expect(find.byKey(const Key('pin-lockout-countdown')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('lecturer-pin-submit')))
          .onPressed,
      isNull,
      reason: 'the submit button must stay disabled while locked out',
    );
    expect(find.byType(AlertDialog), findsOneWidget);

    // Typing the correct PIN during the lockout must not verify anything.
    await tester.enterText(
      find.byKey(const Key('lecturer-pin-input')),
      '5729',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('lecturer-pin-submit')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('pin-lockout-countdown')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('lecturer-pin-input')),
      '5729',
    );
    await tester.tap(find.byKey(const Key('lecturer-pin-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(verified, isTrue);
  });
}

class _MemoryPinSecretStore implements PinSecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

Future<List<int>> _fastTestHash(String pin, List<int> salt) async =>
    List<int>.generate(
      32,
      (index) =>
          (pin.codeUnitAt(index % pin.length) +
              salt[index % salt.length] +
              index) &
          0xff,
    );
