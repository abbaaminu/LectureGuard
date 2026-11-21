import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';

class ClassHistoryScreen extends ConsumerStatefulWidget {
  final Lecture lecture;

  const ClassHistoryScreen({super.key, required this.lecture});

  @override
  ConsumerState<ClassHistoryScreen> createState() => _ClassHistoryScreenState();
}

class _ClassHistoryScreenState extends ConsumerState<ClassHistoryScreen> {
  List<Map<String, Object?>> _sessions = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await ref
          .read(localDatabaseProvider)
          .getLectureHistory(widget.lecture.id);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.lecture.courseCode} History')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Could not load class history: $_error'),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _loadHistory,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _sessions.isEmpty
                  ? const Center(child: Text('No completed sessions cached.'))
                  : ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        final session = _sessions[index];
                        return ListTile(
                          title: Text('${session['session_date']}'),
                          subtitle: Text(
                            '${session['checked_in_count'] ?? 0} present/late · '
                            '${session['absent_count'] ?? 0} absent · '
                            '${session['enrolled_count']} enrolled',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ClassSessionHistoryScreen(
                                sessionId: session['id']! as String,
                                sessionDate: session['session_date']! as String,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class ClassSessionHistoryScreen extends ConsumerStatefulWidget {
  final String sessionId;
  final String sessionDate;

  const ClassSessionHistoryScreen({
    super.key,
    required this.sessionId,
    required this.sessionDate,
  });

  @override
  ConsumerState<ClassSessionHistoryScreen> createState() =>
      _ClassSessionHistoryScreenState();
}

class _ClassSessionHistoryScreenState
    extends ConsumerState<ClassSessionHistoryScreen> {
  List<Map<String, Object?>> _records = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await ref
          .read(localDatabaseProvider)
          .getSessionHistoryRecords(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Attendance · ${widget.sessionDate}')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Could not load session details: $_error'),
                        OutlinedButton(
                          onPressed: _loadRecords,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      final name = [
                        record['last_name'],
                        record['first_name'],
                      ].whereType<String>().where((part) => part.isNotEmpty).join(', ');
                      return ListTile(
                        title: Text(name.isEmpty
                            ? 'Student ${record['student_code'] ?? ''}'
                            : name),
                        subtitle: Text(
                          '${record['student_code'] ?? ''}'
                          '${record['override_reason'] == null ? '' : ' · ${record['override_reason']}'}',
                        ),
                        trailing: Text(
                          (record['status'] as String).toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      );
                    },
                  ),
      );
}
