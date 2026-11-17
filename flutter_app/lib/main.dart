import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'providers/lecture_guard_providers.dart';
import 'screens/teacher_monitor_screen.dart';
import 'screens/admin_analytics_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );

  runApp(const ProviderScope(child: LectureGuardApp()));
}

class LectureGuardApp extends ConsumerStatefulWidget {
  const LectureGuardApp({super.key});

  @override
  ConsumerState<LectureGuardApp> createState() => _LectureGuardAppState();
}

class _LectureGuardAppState extends ConsumerState<LectureGuardApp> {
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(pinSecurityProvider).ensurePinInitialized();
      // Provider initialization binds connection-agnostic (Wi-Fi + Cellular) auto-sync
      ref.read(lectureSessionProvider);
    });
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
      home: Scaffold(
        body: IndexedStack(
          index: _tabIndex,
          children: const [
            TeacherMonitorScreen(),
            AdminAnalyticsScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (i) => setState(() => _tabIndex = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.fact_check_outlined),
              label: 'Teacher Monitor',
            ),
            NavigationDestination(
              icon: Icon(Icons.analytics_outlined),
              label: 'Admin Analytics',
            ),
          ],
        ),
      ),
    );
  }
}
