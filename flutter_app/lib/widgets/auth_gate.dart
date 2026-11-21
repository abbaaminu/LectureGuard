import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_models.dart';
import '../screens/admin_analytics_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/student_attendance_screen.dart';
import '../screens/student_pass_mode_screen.dart';
import '../screens/teacher_monitor_screen.dart';
import '../providers/lecture_guard_providers.dart';

class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  Future<UserRole?>? _roleFuture;

  @override
  void initState() {
    super.initState();
    final authService = ref.read(authServiceProvider);
    _session = authService.currentSession;
    _roleFuture = _loadRole(_session);
    _authSubscription = authService.authStateChanges.listen((data) {
      if (data.session?.user.id == _session?.user.id) {
        _session = data.session;
        return;
      }
      setState(() {
        _session = data.session;
        _roleFuture = _loadRole(data.session);
      });
    });
  }

  Future<UserRole?>? _loadRole(Session? session) {
    if (session == null) {
      // Deferred: initState calls this while the tree is building, and Riverpod
      // forbids modifying a provider during a build.
      Future.microtask(() {
        if (!mounted) return;
        ref.read(lectureSessionProvider.notifier).clearActiveSessionState();
      });
      return null;
    }
    return _loadRoleAndSession(session.user.id);
  }

  Future<UserRole?> _loadRoleAndSession(String userId) async {
    final notifier = ref.read(lectureSessionProvider.notifier);
    await notifier.initialization;
    final role = await ref.read(authServiceProvider).getProfileRole(userId);
    if (role == UserRole.teacher) {
      await notifier.restoreActiveSession(userId);
    } else {
      notifier.clearActiveSessionState();
    }
    return role;
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) return const SignInScreen();
    final sessionState = ref.watch(lectureSessionProvider);
    return FutureBuilder<UserRole?>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _AccessMessage(
            message: 'Could not load your school profile: ${snapshot.error}',
            onSignOut: () => ref.read(authServiceProvider).signOut(),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (sessionState.isRestoring) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final role = snapshot.data;
        final screen = authGateScreenForRole(role, sessionState);
        if (screen != null) return screen;
        return _AccessMessage(
          message: role == null
              ? 'Your account does not have a school profile yet.'
              : 'This account role is not supported.',
          onSignOut: () => ref.read(authServiceProvider).signOut(),
        );
      },
    );
  }
}

/// Maps a resolved role to the screen the gate renders, or null when the caller
/// should show the access message. Extracted so the routing table can be tested
/// without a live Supabase session.
Widget? authGateScreenForRole(UserRole? role, SessionState sessionState) {
  if (role == UserRole.teacher) {
    if (sessionState.activeSession?.isLockedPassMode == true) {
      return const StudentPassModeScreen(authGateManaged: true);
    }
    return const TeacherMonitorScreen();
  }
  if (role == UserRole.admin) return const AdminAnalyticsScreen();
  if (role == UserRole.student) return const StudentAttendanceScreen();
  return null;
}

class _AccessMessage extends StatelessWidget {
  final String message;
  final VoidCallback onSignOut;

  const _AccessMessage({required this.message, required this.onSignOut});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: onSignOut,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      );
}
