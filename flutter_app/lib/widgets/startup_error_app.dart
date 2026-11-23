import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fallback UI rendered when startup initialisation throws.
///
/// A failure inside [Supabase.initialize] or the WorkManager registration would
/// otherwise leave the user on the native splash screen and end in an
/// "app keeps stopping" dialog with no clue about what went wrong. Rendering the
/// exception instead keeps the app open and makes the failure reportable.
class StartupErrorApp extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;

  const StartupErrorApp({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LectureGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0F766E),
      ),
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final retry = onRetry;
          return Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 40,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'LectureGuard could not start',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'The app failed while preparing its local data and cloud '
                        'connection. No attendance records have been changed, so '
                        'retrying or reinstalling is safe.',
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          '$error',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          if (retry != null)
                            FilledButton.icon(
                              onPressed: retry,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: '$error'),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Error details copied.'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy details'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
