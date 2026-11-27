import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_models.dart';
import 'local_database_service.dart';

class AuthService {
  final SupabaseClient _client;
  final LocalDatabaseService? _database;

  AuthService({SupabaseClient? client, LocalDatabaseService? database})
      : _client = client ?? Supabase.instance.client,
        _database = database;

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
    final roleName = profile?['role'] as String?;
    await _database?.cacheUserProfileRole(userId, roleName);
    // Unknown role values are treated as "no profile" rather than thrown: the
    // access gate then shows its message instead of the screen failing.
    return userRoleFromName(roleName);
  }

  Future<UserRole?> getCachedProfileRole(String userId) async {
    final roleName = await _database?.getCachedUserProfileRole(userId);
    return userRoleFromName(roleName);
  }

  Future<void> signOut() => _client.auth.signOut();
}
