import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';
import 'change_lecturer_pin_screen.dart';
import '../services/sync_engine_service.dart';
import '../widgets/teacher_override_dialog.dart';
import 'class_history_screen.dart';
import 'lecture_picker_screen.dart';

class TeacherMonitorScreen extends ConsumerStatefulWidget {
  const TeacherMonitorScreen({super.key});

  @override
  ConsumerState<TeacherMonitorScreen> createState() =>
      _TeacherMonitorScreenState();
}

class _TeacherMonitorScreenState extends ConsumerState<TeacherMonitorScreen> {
  bool _loadingLectures = true;
  bool _startingSession = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadLectures);
  }

  Future<void> _loadLectures() async {
    try {
      await ref.read(lectureSessionProvider.notifier).loadTeacherLectures();
      if (!mounted) return;
      setState(() {
        _loadingLectures = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLectures = false;
        _loadError = 'Could not load assigned classes: $error';
      });
    }
  }

  Future<void> _chooseLecture() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LecturePickerScreen()),
    );
  }

  Future<void> _startSession() async {
    final state = ref.read(lectureSessionProvider);
    final lecture = state.activeLecture;
    if (lecture == null || state.roster.isEmpty) return;
    setState(() => _startingSession = true);
    try {
      final notifier = ref.read(lectureSessionProvider.notifier);
      await notifier.startPassModeSession(
        lecture: lecture,
        students: state.roster,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Session ready. Launch Pass Mode when ready.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start attendance: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _startingSession = false);
    }
  }

  Future<void> _launchPassMode() async {
    try {
      await ref.read(lectureSessionProvider.notifier).lockPassMode();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not launch Pass Mode: $error')),
        );
      }
    }
  }

  Future<void> _endSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End attendance session?'),
        content: const Text(
          'Students without a check-in will be marked absent, and the session will be queued for sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final result =
          await ref.read(lectureSessionProvider.notifier).endSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success
                ? 'Session ended and synced.'
                : 'Session ended and queued locally: ${result.error ?? 'sync unavailable'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not end session: $error')),
        );
      }
    }
  }

  Future<void> _overrideStatus({
    required Student student,
    required AttendanceRecord? record,
  }) async {
    final request = await showDialog<TeacherOverrideRequest>(
      context: context,
      builder: (context) => TeacherOverrideDialog(
        studentName: student.fullName,
        initialStatus: record?.status ?? AttendanceStatus.absent,
        overridingBiometricCheckIn: record?.biometricVerified == true,
        ),
    );
    if (request == null) return;
    try {
      await ref.read(lectureSessionProvider.notifier).teacherOverrideStatus(
            student: student,
            status: request.status,
            reason: request.reason,
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save attendance override: $error')),
        );
      }
    }
  }

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
  Widget build(BuildContext context) {
    final ref = this.ref;
    final state = ref.watch(lectureSessionProvider);
    final progress = state.syncProgress;
    final session = state.activeSession;
    final hasActiveSession = session != null && session.endedAt == null;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Teacher Monitor'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeLecturerPinScreen(
                  pinService: ref.read(pinSecurityProvider),
                ),
              ),
            ),
            icon: const Icon(Icons.key),
            tooltip: 'Change lecturer PIN',
          ),
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
          IconButton(
            onPressed: () => ref.read(authServiceProvider).signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loadingLectures)
                  const LinearProgressIndicator()
                else if (_loadError != null && state.availableLectures.isEmpty)
                  Text(
                    _loadError!,
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        state.activeLecture == null
                            ? 'No lecture selected'
                            : '${state.activeLecture!.courseCode} · ${state.activeLecture!.title}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: hasActiveSession ? null : _chooseLecture,
                        icon: const Icon(Icons.class_outlined),
                        label: const Text('Choose lecture'),
                      ),
                      if (state.activeLecture != null)
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ClassHistoryScreen(
                                lecture: state.activeLecture!,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.history),
                          label: const Text('Class history (offline)'),
                        ),
                      if (state.activeLecture != null)
                        Text(
                          '${state.enrolledCount} students · '
                          'Period ${state.activeLecture!.periodNumber} · '
                          'Room ${state.activeLecture!.roomNumber}',
                        ),
                      if (_loadError != null)
                        Text(
                          _loadError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (session != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            session.endedAt == null
                                ? 'Session active · ${session.sessionDate}'
                                : 'Session ended · ${session.sessionDate}',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: _startingSession ||
                                    state.activeLecture == null ||
                                    state.roster.isEmpty ||
                                    hasActiveSession
                                ? null
                                : _startSession,
                            child: _startingSession
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Start Session'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed:
                                hasActiveSession ? _launchPassMode : null,
                            icon: const Icon(Icons.phonelink_lock),
                            label: const Text('Launch Pass Mode'),
                          ),
                          OutlinedButton(
                            onPressed: hasActiveSession ? _endSession : null,
                            child: const Text('End Session'),
                          ),
                        ],
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(
                  'Enrolled: ${state.enrolledCount}  |  Checked In: ${state.checkedInCount}  |  Absent: ${state.absentCount}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
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
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(status.name.toUpperCase()),
                        IconButton(
                          onPressed: hasActiveSession
                              ? () => _overrideStatus(
                                    student: student,
                                    record: record,
                                  )
                              : null,
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Override ${student.fullName} attendance',
                        ),
                      ],
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
