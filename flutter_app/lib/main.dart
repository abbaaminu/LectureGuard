import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'providers/lecture_guard_providers.dart';
import 'screens/lecturer_pin_setup_screen.dart';
import 'services/background_sync_service.dart';
import 'widgets/auth_gate.dart';
import 'widgets/startup_error_app.dart';

/// Returns null when the dart-define configuration is usable, otherwise a
/// human-readable description of the first problem found.
///
/// The URL check is deliberately strict: Supabase clients send the anon key as
/// a header on every request, so a plain-HTTP or relative URL would leak it (or
/// silently talk to the wrong host).
String? validateSupabaseConfiguration({
  required String url,
  required String anonKey,
}) {
  if (url.isEmpty || anonKey.isEmpty) {
    return 'Copy env.example.json to env.json, fill in your Supabase project URL '
        'and anon/publishable key, then run flutter run '
        '--dart-define-from-file=env.json.';
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
    return 'SUPABASE_URL must be an absolute https URL such as '
        'https://<project-ref>.supabase.co; "$url" was rejected so the anon key '
        'is never sent over an insecure connection.';
  }
  return null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  final configurationProblem = validateSupabaseConfiguration(
    url: supabaseUrl,
    anonKey: supabaseKey,
  );
  if (configurationProblem != null) {
    runApp(_ConfigurationRequiredApp(problem: configurationProblem));
    return;
  }

  _supabaseUrl = supabaseUrl;
  _supabaseKey = supabaseKey;
  await _startApp();
}

/// Configured Supabase endpoint, kept so [_startApp] can be retried from
/// [StartupErrorApp] without re-reading the compile-time dart-defines.
String _supabaseUrl = '';
String _supabaseKey = '';

/// `Supabase.initialize` throws when called twice, so a retry only repeats the
/// steps that have not succeeded yet.
bool _supabaseInitialized = false;

/// Initialises Supabase and the background sync worker, then shows the app.
///
/// Startup failures (unwritable storage, a broken keystore, a plugin that failed
/// to register) are reported on [StartupErrorApp] instead of killing the
/// process: the lecturer can retry and report the exception verbatim rather than
/// watching the launcher icon bounce back to the home screen.
Future<void> _startApp() async {
  try {
    if (!_supabaseInitialized) {
      await Supabase.initialize(
        url: _supabaseUrl,
        publishableKey: _supabaseKey,
      );
      _supabaseInitialized = true;
    }
    await initializeBackgroundSync();
    runApp(const ProviderScope(child: LectureGuardApp()));
  } catch (error, stackTrace) {
    debugPrint('LectureGuard startup failed: $error\n$stackTrace');
    runApp(StartupErrorApp(error: error, onRetry: _startApp));
  }
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
  final String problem;

  const _ConfigurationRequiredApp({required this.problem});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LectureGuard setup',
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Supabase configuration required',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(problem),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
