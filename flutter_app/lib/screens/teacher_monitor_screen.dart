import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';
import '../services/sync_engine_service.dart';
import 'student_pass_mode_screen.dart';

class TeacherMonitorScreen extends ConsumerWidget {
  const TeacherMonitorScreen({super.key});

  String _transportLabel(NetworkTransport transport) {
    switch (transport) {
      case NetworkTransport.wifi:
        return 'Wi-Fi';
      case NetworkTransport.mobile:
        return 'Mobile Data';
      case NetworkTransport.ethernet:
        return 'Ethernet';
      case NetworkTransport.offline:
        return 'Offline';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lectureSessionProvider);
    final progress = state.syncProgress;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Teacher Live Monitor'),
        actions: [
          TextButton.icon(
            onPressed: state.isSyncing
                ? null
                : () async {
                    final res = await ref
                        .read(lectureSessionProvider.notifier)
                        .syncNow();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          res.success
                              ? 'Synced ${res.uploadedCount} records across ${res.batchesCompleted} batch(es) via ${_transportLabel(res.transport)}'
                              : (res.error ?? 'Queued safely in SQLite WAL'),
                        ),
                      ),
                    );
                  },
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(
              progress != null
                  ? 'Batch ${progress.currentBatch}/${progress.totalBatches}'
                  : 'Sync (${state.pendingSyncCount}) · ${_transportLabel(state.networkTransport)}',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Enrolled: ${state.enrolledCount}  |  Checked In: ${state.checkedInCount}  |  Absent: ${state.absentCount}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const StudentPassModeScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.phonelink_lock),
                  label: const Text('Launch Pass Mode'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemExtent: 72,
              itemCount: state.roster.length,
              itemBuilder: (context, idx) {
                final student = state.roster[idx];
                final record = state.recordsByStudentId[student.id];
                final status = record?.status ?? AttendanceStatus.absent;

                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                  ),
                  child: ListTile(
                    title: Text(student.fullName),
                    subtitle: Text(
                      '${student.studentCode} · ${record?.biometricVerified == true ? "Biometric Verified" : "Pending / Manual"}',
                    ),
                    trailing: DropdownButton<AttendanceStatus>(
                      value: status,
                      underline: const SizedBox.shrink(),
                      items: AttendanceStatus.values
                          .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.name.toUpperCase()),
                              ))
                          .toList(),
                      onChanged: (newStatus) {
                        if (newStatus != null) {
                          ref
                              .read(lectureSessionProvider.notifier)
                              .teacherOverrideStatus(
                                student: student,
                                status: newStatus,
                                reason: 'Teacher manual override',
                              );
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
