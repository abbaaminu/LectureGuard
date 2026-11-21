import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/lecture_guard_providers.dart';

class StudentAttendanceScreen extends ConsumerStatefulWidget {
  const StudentAttendanceScreen({super.key});

  @override
  ConsumerState<StudentAttendanceScreen> createState() =>
      _StudentAttendanceScreenState();
}

class _StudentAttendanceScreenState
    extends ConsumerState<StudentAttendanceScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _records = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAttendance();
  }

  Future<void> _loadAttendance() async {
    try {
      final client = Supabase.instance.client;
      final summary = await client
          .from('v_student_attendance_summary')
          .select()
          .maybeSingle();
      final records = await client
          .from('attendance_records')
          .select('id,status,checked_in_at,lectures(course_code,title)')
          .order('checked_in_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _records = List<Map<String, dynamic>>.from(records);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('My Attendance'),
          actions: [
            IconButton(
              onPressed: () => ref.read(authServiceProvider).signOut(),
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Could not load attendance: $_error'),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _loadAttendance,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadAttendance,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _records.isEmpty ? 3 : _records.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _AttendanceSummary(summary: _summary);
                        }
                        if (index == 1) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Attendance records',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          );
                        }
                        if (_records.isEmpty) {
                          return const ListTile(
                            title: Text('No attendance records yet.'),
                          );
                        }
                        return _recordTile(_records[index - 2]);
                      },
                    ),
                  ),
      );

  Widget _recordTile(Map<String, dynamic> record) {
    final lecture = record['lectures'] as Map<String, dynamic>?;
    final checkedInAt = record['checked_in_at'] as String?;
    final subtitle = checkedInAt == null
        ? 'No check-in time recorded'
        : DateTime.parse(checkedInAt).toLocal().toString();
    return ListTile(
      leading: const Icon(Icons.fact_check_outlined),
      title: Text(
        '${lecture?['course_code'] ?? 'Class'} · ${lecture?['title'] ?? ''}'
            .trim(),
      ),
      subtitle: Text(subtitle),
      trailing: Text(
        (record['status'] as String).toUpperCase(),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _AttendanceSummary extends StatelessWidget {
  final Map<String, dynamic>? summary;

  const _AttendanceSummary({required this.summary});

  @override
  Widget build(BuildContext context) {
    if (summary == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Your attendance summary is not available yet.'),
        ),
      );
    }
    final flagged = summary!['chronic_absenteeism_flag'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${summary!['attendance_percentage']}% attendance',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${summary!['attended_sessions']} of '
              '${summary!['total_sessions']} sessions attended',
            ),
            if (flagged)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Your attendance is below 80%.',
                  style: TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
