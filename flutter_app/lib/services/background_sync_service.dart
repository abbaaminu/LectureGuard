import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'local_database_service.dart';
import 'sync_engine_service.dart';

const _backgroundSyncTask = 'com.lectureguard.lectureGuard.backgroundSync';

Future<void> initializeBackgroundSync() async {
  await Workmanager().initialize(backgroundSyncDispatcher);
  await Workmanager().registerPeriodicTask(
    _backgroundSyncTask,
    _backgroundSyncTask,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != _backgroundSyncTask) {
      throw StateError('Unexpected background task: $taskName');
    }

    WidgetsFlutterBinding.ensureInitialized();
    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
      throw StateError('Supabase is not configured for background sync.');
    }

    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseKey,
    );
    final database = LocalDatabaseService();
    final syncEngine = SyncEngineService(
      database,
      Supabase.instance.client,
    );
    try {
      final result = await syncEngine.syncPendingRecords();
      return result.success;
    } finally {
      syncEngine.dispose();
      await database.close();
    }
  });
}
