import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_database_service.dart';

enum NetworkTransport { offline, wifi, mobile, ethernet }

class SyncProgress {
  final int uploadedCount;
  final int totalQueued;
  final int currentBatch;
  final int totalBatches;
  final NetworkTransport transport;

  const SyncProgress({
    required this.uploadedCount,
    required this.totalQueued,
    required this.currentBatch,
    required this.totalBatches,
    required this.transport,
  });
}

class SyncResult {
  final int uploadedCount;
  final int remainingPendingCount;
  final int batchesCompleted;
  final bool success;
  final NetworkTransport transport;
  final String? error;

  const SyncResult({
    required this.uploadedCount,
    required this.remainingPendingCount,
    required this.batchesCompleted,
    required this.success,
    required this.transport,
    this.error,
  });
}

class SyncEngineService {
  static const int batchChunkSize = 50;
  static const int maxChunkRetries = 3;
  static const Duration syncInterval = Duration(seconds: 60);
  static const Duration _reachabilityTimeout = Duration(seconds: 5);

  final LocalDatabaseService _localDb;
  final SupabaseClient _supabase;
  final Connectivity _connectivity;
  final Stream<List<ConnectivityResult>>? _connectivityChanges;
  final Future<List<ConnectivityResult>> Function()? _connectivityCheck;
  final Future<bool> Function()? _reachabilityCheck;
  final Duration Function(int attempt) _retryDelay;
  final String? Function()? _currentUserIdOverride;
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = _reachabilityTimeout;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicSyncTimer;
  Timer? _debouncedSyncTimer;
  bool _isSyncing = false;
  bool _syncRequestedWhileBusy = false;
  bool _disposed = false;
  void Function(SyncResult result)? _onAutoSyncComplete;

  SyncEngineService(
    this._localDb,
    this._supabase, {
    Connectivity? connectivity,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
    Future<bool> Function()? reachabilityCheck,
    Duration Function(int attempt)? retryDelay,
    String? Function()? currentUserId,
  })  : _connectivity = connectivity ?? Connectivity(),
        _connectivityChanges = connectivityChanges,
        _connectivityCheck = connectivityCheck,
        _reachabilityCheck = reachabilityCheck,
        _currentUserIdOverride = currentUserId,
        _retryDelay = retryDelay ??
            ((attempt) => Duration(milliseconds: 500 * attempt * attempt));

  String? get _currentUserId {
    final override = _currentUserIdOverride;
    if (override != null) return override();
    try {
      return _supabase.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// Triggers sync over Wi-Fi, mobile data, and Ethernet.
  void startAutoSyncListener({
    void Function(NetworkTransport transport)? onConnectivityChanged,
    void Function(SyncProgress progress)? onBatchProgress,
    void Function(SyncResult result)? onSyncComplete,
  }) {
    if (_disposed) return;
    _onAutoSyncComplete = onSyncComplete;
    _connectivitySub?.cancel();
    _connectivitySub =
        (_connectivityChanges ?? _connectivity.onConnectivityChanged)
            .listen((results) async {
      if (_disposed) return;
      final transport = _resolveTransport(results);
      onConnectivityChanged?.call(transport);
      final result = await syncPendingRecords(onBatchProgress: onBatchProgress);
      if (!_disposed) onSyncComplete?.call(result);
    });
    unawaited(_refreshPendingTimer());
    unawaited(
      syncPendingRecords(onBatchProgress: onBatchProgress).then((result) {
        if (!_disposed) onSyncComplete?.call(result);
      }),
    );
  }

  NetworkTransport _resolveTransport(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkTransport.wifi;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkTransport.ethernet;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkTransport.mobile;
    }
    if (results.contains(ConnectivityResult.vpn)) {
      return NetworkTransport.mobile;
    }
    return NetworkTransport.offline;
  }

  Future<NetworkTransport> currentTransport() async {
    final results =
        await (_connectivityCheck?.call() ?? _connectivity.checkConnectivity());
    return _resolveTransport(results);
  }

  Future<bool> isOnline() async {
    return (await currentTransport()) != NetworkTransport.offline;
  }

  void scheduleDebouncedSync({
    Duration delay = const Duration(seconds: 2),
  }) {
    if (_disposed) return;
    _debouncedSyncTimer?.cancel();
    _debouncedSyncTimer = Timer(delay, () {
      if (!_disposed) unawaited(syncPendingRecords());
    });
  }

  /// Uploads pending SQLite rows in 50-row chunks, with sessions before records.
  Future<SyncResult> syncPendingRecords({
    void Function(SyncProgress progress)? onBatchProgress,
  }) async {
    final transport = await currentTransport();
    if (_disposed) {
      return SyncResult(
        uploadedCount: 0,
        remainingPendingCount: await _localDb.getPendingSyncCount(),
        batchesCompleted: 0,
        success: false,
        transport: transport,
        error: 'Sync engine has been disposed.',
      );
    }
    if (_isSyncing) {
      _syncRequestedWhileBusy = true;
      return SyncResult(
        uploadedCount: 0,
        remainingPendingCount: await _localDb.getPendingSyncCount(),
        batchesCompleted: 0,
        success: false,
        transport: transport,
        error: 'A sync is already in progress.',
      );
    }

    _isSyncing = true;
    var totalUploaded = 0;
    var batchesCompleted = 0;
    final errors = <String>[];

    try {
      if (transport == NetworkTransport.offline) {
        return SyncResult(
          uploadedCount: 0,
          remainingPendingCount: await _localDb.getPendingSyncCount(),
          batchesCompleted: 0,
          success: false,
          transport: NetworkTransport.offline,
          error: 'Device offline; attendance remains queued locally.',
        );
      }
      if (!await _hasReachability()) {
        return SyncResult(
          uploadedCount: 0,
          remainingPendingCount: await _localDb.getPendingSyncCount(),
          batchesCompleted: 0,
          success: false,
          transport: transport,
          error: 'Supabase is unreachable; attendance remains queued locally.',
        );
      }

      final pendingSessions = await _localDb.getPendingSyncSessions();
      for (var i = 0; i < pendingSessions.length; i += batchChunkSize) {
        if (await currentTransport() == NetworkTransport.offline ||
            !await _hasReachability()) {
          errors.add('Connection lost before the next session batch.');
          break;
        }
        final chunk = pendingSessions.skip(i).take(batchChunkSize).toList();
        try {
          await _upsertChunkWithRetry(
            'attendance_sessions',
            chunk.map((session) => session.toSupabasePayload()).toList(),
            'id',
          );
          await _localDb
              .markSessionsSynced(chunk.map((session) => session.id).toList());
          batchesCompleted++;
        } catch (error) {
          final message = error.toString();
          await _localDb.markSessionsFailed(
            chunk.map((session) => session.id).toList(),
            message,
          );
          errors.add('attendance_sessions batch failed: $message');
        }
      }

      final pending = await _localDb.getPendingSyncRecords();
      final totalQueued = await _localDb.getPendingSyncCount();
      final totalBatches = (pending.length / batchChunkSize).ceil();
      for (var i = 0; i < pending.length; i += batchChunkSize) {
        final activeTransport = await currentTransport();
        if (activeTransport == NetworkTransport.offline ||
            !await _hasReachability()) {
          errors.add('Connection lost before the next attendance batch.');
          break;
        }

        final chunk = pending.skip(i).take(batchChunkSize).toList();
        final chunkIndex = (i ~/ batchChunkSize) + 1;
        try {
          await _upsertChunkWithRetry(
            'attendance_records',
            chunk.map((record) => record.toSupabasePayload()).toList(),
            // Records carry the deterministic (session, student) id, so the
            // conflict target is the primary key. Upserting on the natural key
            // instead used to leave the local and cloud ids out of step.
            'id',
          );
          totalUploaded += await _localDb.markRecordsSynced(chunk);
        } catch (error) {
          final message = error.toString();
          await _localDb.markRecordsFailed(chunk, message);
          errors.add('attendance_records batch $chunkIndex failed: $message');
        }

        batchesCompleted++;
        if (!_disposed) {
          onBatchProgress?.call(
            SyncProgress(
              uploadedCount: totalUploaded,
              totalQueued: totalQueued,
              currentBatch: chunkIndex,
              totalBatches: totalBatches,
              transport: activeTransport,
            ),
          );
        }
      }

      await _localDb.prepareEndedSessionsForSubmission();
      final submissionUpdates =
          await _localDb.getPendingSessionSubmissionUpdates();
      if (submissionUpdates.isNotEmpty) {
        if (await currentTransport() == NetworkTransport.offline ||
            !await _hasReachability()) {
          errors.add('Connection lost before session submission updates.');
        } else {
          for (final update in submissionUpdates) {
            final sessionId = update['id'] as String;
            final submittedAt = update['submitted_to_cloud_at'] as String;
            try {
              final response = await _supabase
                  .from('attendance_sessions')
                  .update({'submitted_to_cloud_at': submittedAt})
                  .eq('id', sessionId)
                  .select('id')
                  .maybeSingle()
                  .timeout(const Duration(seconds: 15));
              if (response == null || response['id'] != sessionId) {
                throw StateError(
                  'The cloud did not confirm the session submission update.',
                );
              }
              final markedCount = await _localDb.markSessionSubmissionSynced(
                sessionId,
                submittedAt,
              );
              if (markedCount != 1) {
                throw StateError(
                  'The local session submission changed before its cloud acknowledgement.',
                );
              }
            } catch (error) {
              final message = 'Session submission update failed: $error';
              await _localDb.markSessionsFailed([sessionId], message);
              errors.add(message);
            }
          }
        }
      }

      final teacherId = _currentUserId;
      if (teacherId != null) {
        errors.addAll(
          await syncPendingLectureTimetableUpdates(teacherId),
        );
      }

      final remaining = await _localDb.getPendingSyncCount();
      final pendingWork = await _getPendingSyncWorkCount();
      return SyncResult(
        uploadedCount: totalUploaded,
        remainingPendingCount: remaining,
        batchesCompleted: batchesCompleted,
        success: pendingWork == 0 && errors.isEmpty,
        transport: transport,
        error: errors.isEmpty ? null : errors.join('; '),
      );
    } catch (error) {
      final remaining = await _localDb.getPendingSyncCount();
      return SyncResult(
        uploadedCount: totalUploaded,
        remainingPendingCount: remaining,
        batchesCompleted: batchesCompleted,
        success: false,
        transport: transport,
        error: 'Sync paused after $batchesCompleted batches: $error',
      );
    } finally {
      _isSyncing = false;
      await _refreshPendingTimer();
      if (!_disposed && _syncRequestedWhileBusy) {
        _syncRequestedWhileBusy = false;
        unawaited(
          syncPendingRecords(onBatchProgress: onBatchProgress).then((result) {
            if (!_disposed) _onAutoSyncComplete?.call(result);
          }),
        );
      }
    }
  }

  Future<bool> _hasReachability() async {
    final check = _reachabilityCheck;
    if (check != null) return check();

    try {
      final request = await _httpClient
          .getUrl(Uri.parse(_supabase.rest.url))
          .timeout(_reachabilityTimeout);
      final response = await request.close().timeout(_reachabilityTimeout);
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 500;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } on HttpException {
      return false;
    }
  }

  Future<void> _upsertChunkWithRetry(
    String table,
    List<Map<String, dynamic>> payload,
    String onConflict,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxChunkRetries; attempt++) {
      try {
        await _supabase
            .from(table)
            .upsert(payload, onConflict: onConflict)
            .timeout(const Duration(seconds: 15));
        return;
      } catch (error) {
        lastError = error;
        if (attempt < maxChunkRetries) {
          await Future.delayed(_retryDelay(attempt));
        }
      }
    }
    throw lastError ?? StateError('Failed to upsert batch chunk.');
  }

  Future<List<String>> syncPendingLectureTimetableUpdates(
    String teacherId,
  ) async {
    final errors = <String>[];
    final pending = await _localDb.getPendingLectureTimetableEdits(teacherId);
    for (final lecture in pending) {
      if (lecture.teacherId != teacherId) continue;
      if (await currentTransport() == NetworkTransport.offline ||
          !await _hasReachability()) {
        errors.add('Connection lost before lecture timetable updates.');
        break;
      }
      try {
        final response = await _supabase
            .from('lectures')
            .update({
              'room_number': lecture.roomNumber,
              'period_number': lecture.periodNumber,
              'academic_term': lecture.academicTerm,
              'late_grace_minutes': lecture.lateGraceMinutes,
            })
            .eq('id', lecture.id)
            .eq('teacher_id', teacherId)
            .select('id')
            .maybeSingle()
            .timeout(const Duration(seconds: 15));
        if (response == null || response['id'] != lecture.id) {
          throw StateError(
            'The cloud did not confirm the timetable update for ${lecture.id}.',
          );
        }
        await _localDb.clearPendingLectureTimetableEdit(lecture.id);
      } catch (error) {
        errors.add('Lecture ${lecture.id} timetable update failed: $error');
      }
    }
    await _refreshPendingTimer();
    return errors;
  }

  Future<int> _getPendingSyncWorkCount() async {
    var pending = await _localDb.getPendingSyncWorkCount();
    final teacherId = _currentUserId;
    if (teacherId != null) {
      pending += await _localDb.getPendingLectureTimetableEditCount(teacherId);
    }
    return pending;
  }

  Future<void> _refreshPendingTimer() async {
    if (_disposed) return;
    final pendingCount = await _getPendingSyncWorkCount();
    if (_disposed) return;
    if (pendingCount > 0) {
      _periodicSyncTimer ??= Timer.periodic(syncInterval, (_) {
        if (!_disposed) unawaited(syncPendingRecords());
      });
    } else {
      _periodicSyncTimer?.cancel();
      _periodicSyncTimer = null;
    }
  }

  void dispose() {
    _disposed = true;
    _periodicSyncTimer?.cancel();
    _debouncedSyncTimer?.cancel();
    _httpClient.close(force: true);
    _connectivitySub?.cancel();
  }
}
