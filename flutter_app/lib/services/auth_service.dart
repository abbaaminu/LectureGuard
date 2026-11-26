import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_models.dart';

class AuthService {
  final SupabaseClient _client;

  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  Session? get currentSession => _client.auth.currentSession;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<UserRole?> getProfileRole(String userId) async {
    final profile = await _client
        .from('profiles')
        .select('role')
        .eq('id', userId)
        .maybeSingle();
    // Unknown role values are treated as "no profile" rather than thrown: the
    // access gate then shows its message instead of the screen failing.
    return userRoleFromName(profile?['role'] as String?);
  }

  Future<void> signOut() => _client.auth.signOut();
}
