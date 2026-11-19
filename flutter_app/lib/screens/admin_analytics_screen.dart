import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/lecture_guard_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AdminAnalyticsScreen extends ConsumerStatefulWidget {
  const AdminAnalyticsScreen({super.key});

  @override
  ConsumerState<AdminAnalyticsScreen> createState() =>
      _AdminAnalyticsScreenState();
}

class _AdminAnalyticsScreenState extends ConsumerState<AdminAnalyticsScreen> {
  List<Map<String, dynamic>> _studentSummaries = [];
  List<Map<String, dynamic>> _teacherLogs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    setState(() => _loading = true);
    try {
      final supabase = Supabase.instance.client;
      final summaries = await supabase
          .from('v_student_attendance_summary')
          .select()
          .order('attendance_percentage', ascending: true);
      final logs = await supabase
          .from('v_teacher_submission_logs')
          .select()
          .order('session_date', ascending: false)
          .limit(30);

      if (!mounted) return;
      setState(() {
        _studentSummaries = List<Map<String, dynamic>>.from(summaries);
        _teacherLogs = List<Map<String, dynamic>>.from(logs);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String generateCsvReport() {
    final rows = <List<dynamic>>[
      [
        'Student Code',
        'Last Name',
        'First Name',
        'Grade',
        'Attendance %',
        'Chronic Flag (<80%)'
      ],
      ..._studentSummaries.map((s) => [
            s['student_code'],
            s['last_name'],
            s['first_name'],
            s['grade_level'],
            s['attendance_percentage'],
            s['chronic_absenteeism_flag'] == true ? 'FLAGGED' : 'OK',
          ]),
    ];
    return const ListToCsvConverter().convert(rows);
  }

  Future<void> exportPdfSummary() async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        build: (ctx) => [
          pw.Header(
              level: 0, text: 'LectureGuard School-Wide Attendance Report'),
          pw.TableHelper.fromTextArray(
            headers: ['Code', 'Student', 'Grade', 'Attendance %', 'Flag'],
            data: _studentSummaries
                .map((s) => [
                      '${s['student_code']}',
                      '${s['last_name']}, ${s['first_name']}',
                      '${s['grade_level']}',
                      '${s['attendance_percentage']}%',
                      s['chronic_absenteeism_flag'] == true
                          ? '<80% ALERT'
                          : 'Normal',
                    ])
                .toList(),
          ),
        ],
      ),
    );
    await Printing.layoutPdf(onLayout: (_) async => doc.save());
  }

  @override
  Widget build(BuildContext context) {
    final chronicList = _studentSummaries
        .where((s) => s['chronic_absenteeism_flag'] == true)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('School Management Analytics'),
        actions: [
          IconButton(
            onPressed: () => ref.read(authServiceProvider).signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
          IconButton(
            onPressed: exportPdfSummary,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Export PDF',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Chronic Absenteeism Watchlist (<80%): ${chronicList.length} Students',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                ...chronicList.map(
                  (s) => ListTile(
                    title: Text('${s['last_name']}, ${s['first_name']}'),
                    subtitle: Text(
                        'Code ${s['student_code']} · Grade ${s['grade_level']}'),
                    trailing: Text(
                      '${s['attendance_percentage']}%',
                      style: const TextStyle(
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Teacher Submission Logs (${_teacherLogs.length})',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
    );
  }
}
