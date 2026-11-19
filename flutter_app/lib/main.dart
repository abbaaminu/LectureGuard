import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'providers/lecture_guard_providers.dart';
import 'screens/lecturer_pin_setup_screen.dart';
import 'services/background_sync_service.dart';
import 'widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
    runApp(const _ConfigurationRequiredApp());
    return;
  }

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabaseKey,
  );
  await initializeBackgroundSync();

  runApp(const ProviderScope(child: LectureGuardApp()));
}

class LectureGuardApp extends ConsumerStatefulWidget {
  const LectureGuardApp({super.key});

  @override
  ConsumerState<LectureGuardApp> createState() => _LectureGuardAppState();
}

class _LectureGuardAppState extends ConsumerState<LectureGuardApp> {
  late Future<bool> _pinConfigured;

  @override
  void initState() {
    super.initState();
    final pinService = ref.read(pinSecurityProvider);
    _pinConfigured = pinService.ensurePinInitialized();
    // Provider initialization binds connection-agnostic (Wi-Fi + Cellular) auto-sync.
    Future.microtask(() => ref.read(lectureSessionProvider));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LectureGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0F766E),
      ),
      home: FutureBuilder<bool>(
        future: _pinConfigured,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load lecturer PIN settings: ${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data != true) {
            return LecturerPinSetupScreen(
              pinService: ref.read(pinSecurityProvider),
              onConfigured: () {
                setState(() => _pinConfigured = Future.value(true));
              },
            );
          }
          return const AuthGate();
        },
      ),
    );
  }
}

class _ConfigurationRequiredApp extends StatelessWidget {
  const _ConfigurationRequiredApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LectureGuard setup',
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Supabase configuration required',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Run with --dart-define=SUPABASE_URL=... and '
                      '--dart-define=SUPABASE_PUBLISHABLE_KEY=... using your '
                      'Supabase project values.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
