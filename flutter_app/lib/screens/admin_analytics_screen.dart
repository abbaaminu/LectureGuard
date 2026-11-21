import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/lecture_guard_providers.dart';
import '../services/csv_export_service.dart';

class AdminAnalyticsScreen extends ConsumerStatefulWidget {
  /// Injectable for widget tests; production uses the Supabase singleton.
  final SupabaseClient? client;

  const AdminAnalyticsScreen({super.key, this.client});

  @override
  ConsumerState<AdminAnalyticsScreen> createState() =>
      _AdminAnalyticsScreenState();
}

class _AdminAnalyticsScreenState extends ConsumerState<AdminAnalyticsScreen> {
  static const _pageSize = 50;

  SupabaseClient get _client => widget.client ?? Supabase.instance.client;

  final _searchController = TextEditingController();
  final _gradeController = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _chronicStudents = [];
  List<Map<String, dynamic>> _teacherLogs = [];
  DateTime? _startDate;
  DateTime? _endDate;
  Object? _chronicError;
  Object? _logsError;
  bool _loadingChronic = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _loadingLogs = true;
  bool _loadingMoreLogs = false;
  bool _hasMoreLogs = true;
  bool _exporting = false;
  bool _savingSettings = false;
  int _chronicRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadChronic();
    _loadTeacherLogs();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _gradeController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _queryParameters() => {
        'p_search': _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        'p_grade_level': int.tryParse(_gradeController.text.trim()),
        'p_start_date': _startDate == null ? null : _dateOnly(_startDate!),
        'p_end_date': _endDate == null ? null : _dateOnly(_endDate!),
      };

  String _dateOnly(DateTime date) => date.toIso8601String().substring(0, 10);

  Future<void> _loadChronic({bool reset = true}) async {
    final requestId = ++_chronicRequestId;
    if (_startDate != null &&
        _endDate != null &&
        _endDate!.isBefore(_startDate!)) {
      setState(() {
        _chronicError = 'End date must be on or after the start date.';
        _loadingChronic = false;
        _loadingMore = false;
      });
      return;
    }

    setState(() {
      _chronicError = null;
      if (reset) {
        _loadingChronic = true;
        _loadingMore = false;
        _hasMore = true;
        _chronicStudents = [];
      } else {
        _loadingMore = true;
      }
    });

    try {
      final offset = reset ? 0 : _chronicStudents.length;
      final rows = await _client
          .rpc(
            'admin_chronic_absentee_page',
            params: _queryParameters(),
          )
          .range(offset, offset + _pageSize - 1);
      if (!mounted || requestId != _chronicRequestId) return;
      final page = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _chronicStudents = reset ? page : [..._chronicStudents, ...page];
        _hasMore = page.length == _pageSize;
        _loadingChronic = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || requestId != _chronicRequestId) return;
      setState(() {
        _chronicError = error;
        _loadingChronic = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadTeacherLogs({bool reset = true}) async {
    setState(() {
      if (reset) {
        _loadingLogs = true;
        _hasMoreLogs = true;
        _teacherLogs = [];
      } else {
        _loadingMoreLogs = true;
      }
      _logsError = null;
    });
    try {
      final offset = reset ? 0 : _teacherLogs.length;
      // The logs view is no longer readable by client roles (migration 004);
      // this SECURITY DEFINER function returns the caller's own sessions for a
      // teacher and every session for an admin.
      final rows = await _client.rpc(
        'teacher_submission_logs',
        params: {'p_limit': 50, 'p_offset': offset},
      );
      if (!mounted) return;
      final page = List<Map<String, dynamic>>.from(rows as List);
      setState(() {
        _teacherLogs = reset ? page : [..._teacherLogs, ...page];
        _hasMoreLogs = page.length == 50;
        _loadingLogs = false;
        _loadingMoreLogs = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logsError = error;
        _loadingLogs = false;
        _loadingMoreLogs = false;
      });
    }
  }

  void _scheduleFilterReload() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _loadChronic(),
    );
  }

  Future<void> _selectDate({required bool start}) async {
    final existing = start ? _startDate : _endDate;
    final selected = await showDatePicker(
      context: context,
      initialDate: existing ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (start) {
        _startDate = selected;
      } else {
        _endDate = selected;
      }
    });
    _loadChronic();
  }

  Future<List<Map<String, dynamic>>> _fetchAllChronicStudents() async {
    final all = <Map<String, dynamic>>[];
    final params = _queryParameters();
    var offset = 0;
    while (true) {
      final rows = await _client
          .rpc(
            'admin_chronic_absentee_page',
            params: params,
          )
          .range(offset, offset + _pageSize - 1);
      final page = List<Map<String, dynamic>>.from(rows);
      all.addAll(page);
      if (page.length < _pageSize) return all;
      offset += _pageSize;
    }
  }

  Future<void> _exportCsv() async {
    setState(() => _exporting = true);
    try {
      final students = await _fetchAllChronicStudents();
      final rows = <List<Object?>>[
        [
          'Student Code',
          'Last Name',
          'First Name',
          'Grade',
          'Homeroom',
          'Total Sessions',
          'Attended Sessions',
          'Attendance %',
          'Chronic Flag (<80%)',
        ],
        ...students.map((student) => [
              student['student_code'],
              student['last_name'],
              student['first_name'],
              student['grade_level'],
              student['homeroom'],
              student['total_sessions'],
              student['attended_sessions'],
              student['attendance_percentage'],
              student['chronic_absenteeism_flag'] == true ? 'FLAGGED' : 'OK',
            ]),
      ];
      final csv = encodeCsvRows(rows);
      await Share.shareXFiles(
        [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(csv)),
            mimeType: 'text/csv',
            name: 'lectureguard-chronic-absenteeism.csv',
          ),
        ],
        subject: 'LectureGuard chronic absenteeism report',
        fileNameOverrides: ['lectureguard-chronic-absenteeism.csv'],
        sharePositionOrigin: _sharePositionOrigin(),
      );
    } catch (error) {
      _showExportError('CSV', error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Rect? _sharePositionOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<void> _exportPdf() async {
    setState(() => _exporting = true);
    try {
      final students = await _fetchAllChronicStudents();
      final regularFont = await rootBundle.load(
        'assets/fonts/Roboto-Regular.ttf',
      );
      final boldFont = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
      final theme = pw.ThemeData.withFont(
        base: pw.Font.ttf(regularFont),
        bold: pw.Font.ttf(boldFont),
      );
      final document = pw.Document();
      document.addPage(
        pw.MultiPage(
          theme: theme,
          build: (_) => [
            pw.Header(
              level: 0,
              text: 'LectureGuard Chronic Absenteeism Report',
            ),
            pw.Paragraph(
              text: 'Students below 80% attendance: ${students.length}',
            ),
            pw.TableHelper.fromTextArray(
              headers: const [
                'Code',
                'Student',
                'Grade',
                'Sessions',
                'Attendance %',
              ],
              data: students
                  .map((student) => [
                        '${student['student_code']}',
                        '${student['last_name']}, ${student['first_name']}',
                        '${student['grade_level']}',
                        '${student['attended_sessions']}/${student['total_sessions']}',
                        '${student['attendance_percentage']}%',
                      ])
                  .toList(),
            ),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (_) async => document.save());
    } catch (error) {
      _showExportError('PDF', error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showExportError(String type, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$type export failed: $error')),
    );
  }

  Future<void> _updateExcusedSetting(bool value) async {
    setState(() => _savingSettings = true);
    try {
      await ref
          .read(lectureSessionProvider.notifier)
          .updateExcusedCountsAsAttended(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update school setting: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  Future<void> _refreshSchoolSettings() async {
    try {
      await ref.read(lectureSessionProvider.notifier).refreshSchoolSettings();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not refresh school setting: $error')),
        );
      }
    }
  }

  Future<void> _showStudentTrend(Map<String, dynamic> student) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _StudentWeeklyTrendDialog(
        studentId: student['student_id'] as String,
        studentName: '${student['first_name']} ${student['last_name']}',
      ),
    );
  }

  Widget _buildChronicTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: 'Search name or student code',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: () {
                      _searchController.clear();
                      _loadChronic();
                    },
                    icon: const Icon(Icons.clear),
                  ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => _scheduleFilterReload(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _gradeController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Grade',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => _scheduleFilterReload(),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _selectDate(start: true),
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                        _startDate == null ? 'From' : _dateOnly(_startDate!)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _selectDate(start: false),
                    icon: const Icon(Icons.event),
                    label: Text(_endDate == null ? 'To' : _dateOnly(_endDate!)),
                  ),
                  TextButton(
                    onPressed: _searchController.text.isEmpty &&
                            _startDate == null &&
                            _endDate == null &&
                            _gradeController.text.isEmpty
                        ? null
                        : () {
                            _searchDebounce?.cancel();
                            setState(() {
                              _searchController.clear();
                              _startDate = null;
                              _endDate = null;
                              _gradeController.clear();
                            });
                            _loadChronic();
                          },
                    child: const Text('Clear filters'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_chronicError != null)
          ListTile(
            title: Text('Could not load chronic absentee list: $_chronicError'),
            trailing: TextButton(
              onPressed: () => _loadChronic(),
              child: const Text('Retry'),
            ),
          ),
        Expanded(
          child: _loadingChronic && _chronicStudents.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _chronicStudents.length +
                      (_hasMore || _loadingMore || _chronicStudents.isEmpty
                          ? 1
                          : 0),
                  itemBuilder: (context, index) {
                    if (index == _chronicStudents.length) {
                      if (_loadingMore) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (_hasMore && _chronicStudents.isNotEmpty) {
                        return Center(
                          child: TextButton(
                            onPressed: () => _loadChronic(reset: false),
                            child: const Text('Load more students'),
                          ),
                        );
                      }
                      return const ListTile(
                        title: Text('No students match these filters.'),
                      );
                    }
                    final student = _chronicStudents[index];
                    return ListTile(
                      leading: const Icon(Icons.warning_amber_outlined,
                          color: Color(0xFFDC2626)),
                      title: Text(
                        '${student['last_name']}, ${student['first_name']}',
                      ),
                      subtitle: Text(
                        'Code ${student['student_code']} · '
                        'Grade ${student['grade_level']} · '
                        '${student['attended_sessions']}/${student['total_sessions']} sessions',
                      ),
                      trailing: Text(
                        '${student['attendance_percentage']}%',
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onTap: () => _showStudentTrend(student),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSubmissionTab() {
    if (_loadingLogs && _teacherLogs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_logsError != null && _teacherLogs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load teacher submission logs: $_logsError'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _loadTeacherLogs,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_logsError != null)
          ListTile(
            title: Text('Could not refresh submission logs: $_logsError'),
            trailing: TextButton(
              onPressed: _loadTeacherLogs,
              child: const Text('Retry'),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadTeacherLogs,
            child: ListView.builder(
              itemCount: _teacherLogs.length +
                  (_hasMoreLogs || _loadingMoreLogs || _teacherLogs.isEmpty
                      ? 1
                      : 0),
              itemBuilder: (context, index) {
                if (index == _teacherLogs.length) {
                  if (_loadingMoreLogs) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (_hasMoreLogs && _teacherLogs.isNotEmpty) {
                    return Center(
                      child: TextButton(
                        onPressed: () => _loadTeacherLogs(reset: false),
                        child: const Text('Load more submission logs'),
                      ),
                    );
                  }
                  return const ListTile(
                    title: Text('No submission logs available.'),
                  );
                }
                final log = _teacherLogs[index];
                final submittedAt = log['submitted_to_cloud_at'] as String?;
                final submitted = submittedAt != null;
                return ListTile(
                  leading: Icon(
                    submitted ? Icons.cloud_done_outlined : Icons.cloud_off,
                    color: submitted ? Colors.green : Colors.orange,
                  ),
                  title: Text(
                    '${log['course_code']} · ${log['lecture_title']}',
                  ),
                  subtitle: Text(
                    '${log['session_date']} · ${log['teacher_name'] ?? 'Teacher'}'
                    '${submitted ? ' · Submitted $submittedAt' : ' · Never submitted'}',
                  ),
                  trailing: Text(
                    '${log['biometric_checked_in_count'] ?? 0}/'
                    '${log['enrolled_snapshot_count'] ?? 0}',
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab(SessionState state) {
    final hasError = state.schoolSettingsError != null;
    return ListView.builder(
      itemCount: hasError ? 2 : 1,
      itemBuilder: (context, index) {
        if (index == 1) {
          return ListTile(
            title: Text(
              'Could not refresh school settings: ${state.schoolSettingsError}',
            ),
            trailing: TextButton(
              onPressed: _refreshSchoolSettings,
              child: const Text('Retry'),
            ),
          );
        }
        return SwitchListTile(
          title: const Text('Count excused as attended'),
          subtitle: const Text(
            'School-wide setting for attendance percentages and chronic-absence reports. Off by default.',
          ),
          value: state.excusedCountsAsAttended,
          onChanged: _savingSettings ? null : _updateExcusedSetting,
          secondary: _savingSettings
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.settings_outlined),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lectureSessionProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('School Management Analytics'),
          actions: [
            IconButton(
              onPressed: _exporting ? null : _exportCsv,
              icon: const Icon(Icons.table_view_outlined),
              tooltip: 'Export filtered chronic-absence CSV',
            ),
            IconButton(
              onPressed: _exporting ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Export filtered chronic-absence PDF',
            ),
            IconButton(
              onPressed: () => ref.read(authServiceProvider).signOut(),
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Chronic Absence'),
              Tab(text: 'Teacher Logs'),
              Tab(text: 'School Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildChronicTab(),
            _buildSubmissionTab(),
            _buildSettingsTab(state),
          ],
        ),
        floatingActionButton: _exporting
            ? const FloatingActionButton(
                onPressed: null,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
    );
  }
}

class _StudentWeeklyTrendDialog extends StatefulWidget {
  final String studentId;
  final String studentName;

  const _StudentWeeklyTrendDialog({
    required this.studentId,
    required this.studentName,
  });

  @override
  State<_StudentWeeklyTrendDialog> createState() =>
      _StudentWeeklyTrendDialogState();
}

class _StudentWeeklyTrendDialogState extends State<_StudentWeeklyTrendDialog> {
  List<Map<String, dynamic>> _weeks = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTrend();
  }

  Future<void> _loadTrend() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await Supabase.instance.client
          .from('v_student_weekly_attendance')
          .select('week_start, attendance_percentage')
          .eq('student_id', widget.studentId)
          .order('week_start');
      if (!mounted) return;
      setState(() {
        _weeks = List<Map<String, dynamic>>.from(rows);
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
    return AlertDialog(
      title: Text('${widget.studentName} · Weekly Attendance'),
      content: SizedBox(
        width: 520,
        height: 280,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Could not load weekly trend: $_error'),
                      TextButton(
                        onPressed: _loadTrend,
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : _weeks.isEmpty
                    ? const Center(
                        child: Text('No weekly attendance data available.'),
                      )
                    : LineChart(_chartData()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  LineChartData _chartData() {
    final spots = <FlSpot>[];
    for (var index = 0; index < _weeks.length; index++) {
      final percent =
          (_weeks[index]['attendance_percentage'] as num).toDouble();
      spots.add(FlSpot(index.toDouble(), percent));
    }
    final interval =
        _weeks.length > 5 ? (_weeks.length / 5).ceilToDouble() : 1.0;
    return LineChartData(
      minY: 0,
      maxY: 100,
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: true),
      titlesData: FlTitlesData(
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        topTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: interval,
            reservedSize: 36,
            getTitlesWidget: (value, meta) {
              final index = value.round();
              if (index < 0 || index >= _weeks.length) {
                return const SizedBox.shrink();
              }
              final week =
                  DateTime.parse(_weeks[index]['week_start'] as String);
              return SideTitleWidget(
                meta: meta,
                child: Text('${week.month}/${week.day}'),
              );
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(show: true),
        ),
      ],
    );
  }
}
