import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_models.dart';
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

  final LocalDatabaseService _localDb;
  final SupabaseClient _supabase;
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isSyncing = false;

  SyncEngineService(this._localDb, this._supabase);

  /// Connection-agnostic listener: automatically triggers sync on Mobile Data,
  /// Wi-Fi, or Ethernet rather than restricting to Wi-Fi only.
  void startAutoSyncListener({
    void Function(NetworkTransport transport)? onConnectivityChanged,
    void Function(SyncProgress progress)? onBatchProgress,
    void Function(SyncResult result)? onSyncComplete,
  }) {
    _connectivitySub?.cancel();
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) async {
      final transport = _resolveTransport(results);
      onConnectivityChanged?.call(transport);

      if (transport != NetworkTransport.offline) {
        final result = await syncPendingRecords(onBatchProgress: onBatchProgress);
        onSyncComplete?.call(result);
      }
    });
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
      // VPN wraps an underlying mobile/wifi interface
      return NetworkTransport.mobile;
    }
    return NetworkTransport.offline;
  }

  Future<NetworkTransport> currentTransport() async {
    final results = await _connectivity.checkConnectivity();
    return _resolveTransport(results);
  }

  Future<bool> isOnline() async {
    return (await currentTransport()) != NetworkTransport.offline;
  }

  /// Uploads pending SQLite WAL records in resilient 50-record chunks with
  /// per-chunk retry & immediate SQLite checkpointing after each chunk.
  Future<SyncResult> syncPendingRecords({
    void Function(SyncProgress progress)? onBatchProgress,
  }) async {
    final transport = await currentTransport();
    if (_isSyncing) {
      final remaining = await _localDb.getPendingSyncCount();
      return SyncResult(
        uploadedCount: 0,
        remainingPendingCount: remaining,
        batchesCompleted: 0,
        success: true,
        transport: transport,
      );
    }

    _isSyncing = true;
    int totalUploaded = 0;
    int batchesCompleted = 0;

    try {
      if (transport == NetworkTransport.offline) {
        final remaining = await _localDb.getPendingSyncCount();
        return SyncResult(
          uploadedCount: 0,
          remainingPendingCount: remaining,
          batchesCompleted: 0,
          success: false,
          transport: NetworkTransport.offline,
          error: 'Device offline. $remaining records safely queued in SQLite WAL.',
        );
      }

      final pending = await _localDb.getPendingSyncRecords();
      if (pending.isEmpty) {
        return SyncResult(
          uploadedCount: 0,
          remainingPendingCount: 0,
          batchesCompleted: 0,
          success: true,
          transport: transport,
        );
      }

      final totalBatches = (pending.length / batchChunkSize).ceil();

      for (int i = 0; i < pending.length; i += batchChunkSize) {
        // Re-check connection before each cellular/Wi-Fi chunk
        final activeTransport = await currentTransport();
        if (activeTransport == NetworkTransport.offline) {
          final remaining = await _localDb.getPendingSyncCount();
          return SyncResult(
            uploadedCount: totalUploaded,
            remainingPendingCount: remaining,
            batchesCompleted: batchesCompleted,
            success: false,
            transport: NetworkTransport.offline,
            error: 'Connection dropped mid-sync. $remaining records remain safely in SQLite WAL.',
          );
        }

        final end = i + batchChunkSize > pending.length
            ? pending.length
            : i + batchChunkSize;
        final chunk = pending.sublist(i, end);
        final payload = chunk.map((r) => r.toSupabasePayload()).toList();
        final chunkIndex = (i ~/ batchChunkSize) + 1;

        await _upsertChunkWithRetry(payload);

        // Immediately checkpoint synced IDs so intermittent cellular drops
        // never lose progress or duplicate already-uploaded chunks.
        final chunkIds = chunk.map((r) => r.id).toList();
        await _localDb.markRecordsSynced(chunkIds);

        totalUploaded += chunkIds.length;
        batchesCompleted += 1;

        onBatchProgress?.call(
          SyncProgress(
            uploadedCount: totalUploaded,
            totalQueued: pending.length,
            currentBatch: chunkIndex,
            totalBatches: totalBatches,
            transport: activeTransport,
          ),
        );
      }

      final remaining = await _localDb.getPendingSyncCount();
      return SyncResult(
        uploadedCount: totalUploaded,
        remainingPendingCount: remaining,
        batchesCompleted: batchesCompleted,
        success: true,
        transport: transport,
      );
    } catch (e) {
      final remaining = await _localDb.getPendingSyncCount();
      return SyncResult(
        uploadedCount: totalUploaded,
        remainingPendingCount: remaining,
        batchesCompleted: batchesCompleted,
        success: false,
        transport: transport,
        error: 'Sync paused after $batchesCompleted batches: $e',
      );
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _upsertChunkWithRetry(List<Map<String, dynamic>> payload) async {
    Object? lastError;
    for (int attempt = 1; attempt <= maxChunkRetries; attempt++) {
      try {
        await _supabase
            .from('attendance_records')
            .upsert(payload, onConflict: 'session_id,student_id')
            .timeout(const Duration(seconds: 15));
        return;
      } catch (e) {
        lastError = e;
        if (attempt < maxChunkRetries) {
          // Exponential backoff (500ms, 1500ms) for weak cellular signals
          await Future.delayed(Duration(milliseconds: 500 * attempt * attempt));
        }
      }
    }
    throw lastError ?? Exception('Failed to upsert batch chunk.');
  }

  void dispose() {
    _connectivitySub?.cancel();
  }
}
