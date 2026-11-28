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
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';
import '../services/csv_export_service.dart';

enum _SchoolRecordKind { attendanceRecords, sessions, students }

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
  final _courseCodeController = TextEditingController();
  final _courseTitleController = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _chronicStudents = [];
  List<Map<String, dynamic>> _teacherLogs = [];
  List<TeacherProfile> _teachers = [];
  List<Lecture> _adminLectures = [];
  List<Map<String, dynamic>> _adminProfiles = [];
  List<Map<String, dynamic>> _schoolRecordRows = [];
  _SchoolRecordKind _schoolRecordKind = _SchoolRecordKind.attendanceRecords;
  final Set<String> _savingProfileIds = {};
  String? _selectedTeacherId;
  DateTime? _startDate;
  DateTime? _endDate;
  Object? _chronicError;
  Object? _logsError;
  Object? _profilesError;
  bool _loadingChronic = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _loadingLogs = true;
  bool _loadingMoreLogs = false;
  bool _hasMoreLogs = true;
  bool _exporting = false;
  bool _savingSettings = false;
  bool _loadingAssignments = true;
  bool _savingAssignment = false;
  bool _loadingProfiles = true;
  bool _creatingStaff = false;
  bool _loadingSchoolRecords = true;
  bool _loadingMoreSchoolRecords = false;
  bool _hasMoreSchoolRecords = true;
  Object? _schoolRecordsError;
  Object? _assignmentError;
  int _chronicRequestId = 0;
  int _schoolRecordsRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadChronic();
    _loadTeacherLogs();
    unawaited(_loadAdminManagementData());
    _loadSchoolRecords();
  }

  Future<void> _loadAdminManagementData() async {
    // Keep local SQLite writes sequential; concurrent cache refreshes can
    // contend for the write lock and leave the screen half-loaded.
    await _loadCourseAssignments();
    await _loadAdminProfiles();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _gradeController.dispose();
    _courseCodeController.dispose();
    _courseTitleController.dispose();
    super.dispose();
  }

  String get _defaultAcademicTerm {
    final now = DateTime.now();
    final term = now.month <= 6 ? 1 : 2;
    return '${now.year}-T$term';
  }

  Future<void> _loadCourseAssignments() async {
    setState(() {
      _loadingAssignments = true;
      _assignmentError = null;
    });
    try {
      final notifier = ref.read(lectureSessionProvider.notifier);
      final teachers = await notifier.loadTeacherProfiles(client: _client);
      final lectures = await notifier.loadAllLectures(client: _client);
      if (!mounted) return;
      setState(() {
        _teachers = teachers;
        _adminLectures = lectures;
        if (_selectedTeacherId == null ||
            !teachers.any((teacher) => teacher.id == _selectedTeacherId)) {
          _selectedTeacherId = teachers.isEmpty ? null : teachers.first.id;
        }
        _loadingAssignments = false;
      });
    } catch (error) {
      final database = ref.read(localDatabaseProvider);
      final cachedProfiles = await database.getCachedAdminProfiles();
      final cachedLectures = await database.getCachedLectures();
      if (!mounted) return;
      setState(() {
        _teachers = cachedProfiles
            .where((profile) => profile['role'] == UserRole.teacher.name)
            .map((profile) => TeacherProfile.fromMap(profile))
            .toList();
        _adminLectures = cachedLectures;
        _assignmentError = error;
        _loadingAssignments = false;
      });
    }
  }

  Future<void> _loadAdminProfiles() async {
    setState(() {
      _loadingProfiles = true;
      _profilesError = null;
    });
    try {
      final profiles = await ref
          .read(lectureSessionProvider.notifier)
          .loadAdminProfiles(client: _client);
      if (!mounted) return;
      setState(() {
        _adminProfiles = profiles;
        _loadingProfiles = false;
      });
    } catch (error) {
      final cached =
          await ref.read(localDatabaseProvider).getCachedAdminProfiles();
      if (!mounted) return;
      setState(() {
        _adminProfiles =
            cached.map((row) => Map<String, dynamic>.from(row)).toList();
        _profilesError = error;
        _loadingProfiles = false;
      });
    }
  }

  Future<void> _loadSchoolRecords({bool reset = true}) async {
    final requestId = ++_schoolRecordsRequestId;
    final kind = _schoolRecordKind;
    final offset = reset ? 0 : _schoolRecordRows.length;
    setState(() {
      _schoolRecordsError = null;
      if (reset) {
        _loadingSchoolRecords = true;
        _loadingMoreSchoolRecords = false;
        _hasMoreSchoolRecords = true;
        _schoolRecordRows = [];
      } else {
        _loadingMoreSchoolRecords = true;
      }
    });

    try {
      final List<Map<String, dynamic>> rows;
      switch (kind) {
        case _SchoolRecordKind.attendanceRecords:
          final response = await _client
              .from('attendance_records')
              .select(
                'id, session_id, lecture_id, student_id, status, '
                'checked_in_at, biometric_verified, biometric_method, '
                'override_reason, device_recorded_at',
              )
              .order('device_recorded_at', ascending: false)
              .range(offset, offset + _pageSize - 1);
          rows = response.map((row) => Map<String, dynamic>.from(row)).toList();
        case _SchoolRecordKind.sessions:
          final response = await _client
              .from('attendance_sessions')
              .select(
                'id, lecture_id, teacher_id, session_date, started_at, '
                'ended_at, enrolled_snapshot_count, submitted_to_cloud_at',
              )
              .order('session_date', ascending: false)
              .order('started_at', ascending: false)
              .range(offset, offset + _pageSize - 1);
          rows = response.map((row) => Map<String, dynamic>.from(row)).toList();
        case _SchoolRecordKind.students:
          final response = await _client
              .from('students')
              .select(
                'id, student_code, first_name, last_name, grade_level, '
                'homeroom, active',
              )
              .order('last_name')
              .order('first_name')
              .range(offset, offset + _pageSize - 1);
          rows = response.map((row) => Map<String, dynamic>.from(row)).toList();
      }
      if (!mounted ||
          requestId != _schoolRecordsRequestId ||
          kind != _schoolRecordKind) {
        return;
      }
      setState(() {
        _schoolRecordRows = reset ? rows : [..._schoolRecordRows, ...rows];
        _hasMoreSchoolRecords = rows.length == _pageSize;
        _loadingSchoolRecords = false;
        _loadingMoreSchoolRecords = false;
      });
    } catch (error) {
      if (!mounted ||
          requestId != _schoolRecordsRequestId ||
          kind != _schoolRecordKind) {
        return;
      }
      setState(() {
        _schoolRecordsError = error;
        _loadingSchoolRecords = false;
        _loadingMoreSchoolRecords = false;
      });
    }
  }

  Future<void> _changeProfileRole(
    Map<String, dynamic> profile,
    UserRole role,
  ) async {
    final currentRole = userRoleFromName(profile['role'] as String?);
    if (currentRole == null || currentRole == role) return;
    final name = profile['full_name'] as String;
    final email = profile['email'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change account role?'),
        content: Text(
            'Set $name ($email) to ${role.name}? If that user is signed in, '
            'they must sign out and back in to pick up the new role.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Change role'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final profileId = profile['id'] as String;
    setState(() => _savingProfileIds.add(profileId));
    try {
      await ref.read(lectureSessionProvider.notifier).setAdminProfileRole(
            profileId: profileId,
            email: email,
            role: role,
            client: _client,
          );
      if (!mounted) return;
      setState(() {
        final index =
            _adminProfiles.indexWhere((row) => row['id'] == profileId);
        if (index >= 0) _adminProfiles[index]['role'] = role.name;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated $name to ${role.name}.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update $email role: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingProfileIds.remove(profileId));
    }
  }

  Future<void> _createStaffLogin() async {
    final details = await showDialog<_StaffLoginFormResult>(
      context: context,
      builder: (_) => const _StaffLoginDialog(),
    );
    if (details == null) return;
    setState(() => _creatingStaff = true);
    try {
      await ref.read(lectureSessionProvider.notifier).createStaffLogin(
            email: details.email,
            password: details.password,
            role: details.role,
            fullName: details.fullName,
            department: details.department,
            client: _client,
          );
      await _loadAdminProfiles();
      await _loadCourseAssignments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${details.role.name} login created.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create staff login: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingStaff = false);
    }
  }

  Future<void> _createCourseAssignment() async {
    final courseCode = _courseCodeController.text.trim();
    final title = _courseTitleController.text.trim();
    final teacherId = _selectedTeacherId;
    if (courseCode.isEmpty || title.isEmpty || teacherId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a course code, title, and select a lecturer.'),
        ),
      );
      return;
    }
    setState(() => _savingAssignment = true);
    try {
      await ref.read(lectureSessionProvider.notifier).createLectureAssignment(
            courseCode: courseCode,
            title: title,
            teacherId: teacherId,
            roomNumber: 'TBD',
            periodNumber: 1,
            academicTerm: _defaultAcademicTerm,
            client: _client,
          );
      if (!mounted) return;
      _courseCodeController.clear();
      _courseTitleController.clear();
      await _loadCourseAssignments();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Course assigned to lecturer.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not assign course: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingAssignment = false);
    }
  }

  Future<void> _changeLectureTeacher(Lecture lecture) async {
    if (_teachers.isEmpty) return;
    var selectedTeacherId = _teachers.any(
      (teacher) => teacher.id == lecture.teacherId,
    )
        ? lecture.teacherId
        : _teachers.first.id;
    final reassignedTeacherId = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reassign lecturer'),
          content: DropdownButtonFormField<String>(
            key: ValueKey(selectedTeacherId),
            initialValue: selectedTeacherId,
            decoration: const InputDecoration(labelText: 'Lecturer'),
            items: _teachers
                .map(
                  (teacher) => DropdownMenuItem(
                    value: teacher.id,
                    child: Text('${teacher.fullName} · ${teacher.email}'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) {
                setDialogState(() => selectedTeacherId = value);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selectedTeacherId),
              child: const Text('Reassign'),
            ),
          ],
        ),
      ),
    );
    if (reassignedTeacherId == null ||
        reassignedTeacherId == lecture.teacherId) {
      return;
    }
    try {
      await ref.read(lectureSessionProvider.notifier).reassignLectureTeacher(
            lectureId: lecture.id,
            teacherId: reassignedTeacherId,
            client: _client,
          );
      await _loadCourseAssignments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lecturer reassigned.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reassign lecturer: $error')),
        );
      }
    }
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

  String _schoolRecordTitle(Map<String, dynamic> row) {
    switch (_schoolRecordKind) {
      case _SchoolRecordKind.attendanceRecords:
        return '${row['status']} · student ${row['student_id']}';
      case _SchoolRecordKind.sessions:
        return '${row['session_date']} · lecture ${row['lecture_id']}';
      case _SchoolRecordKind.students:
        return '${row['last_name']}, ${row['first_name']}';
    }
  }

  String _schoolRecordSubtitle(Map<String, dynamic> row) {
    switch (_schoolRecordKind) {
      case _SchoolRecordKind.attendanceRecords:
        return 'Session ${row['session_id']} · lecture ${row['lecture_id']} · '
            'checked in ${row['checked_in_at'] ?? 'not checked in'} · '
            'biometric ${row['biometric_verified'] == true ? 'verified' : 'not verified'}'
            '${row['biometric_method'] == null ? '' : ' (${row['biometric_method']})'}'
            '${row['override_reason'] == null ? '' : ' · override: ${row['override_reason']}'}';
      case _SchoolRecordKind.sessions:
        return 'Teacher ${row['teacher_id']} · started ${row['started_at']} · '
            'ended ${row['ended_at'] ?? 'in progress'} · '
            '${row['enrolled_snapshot_count']} enrolled · '
            'submitted ${row['submitted_to_cloud_at'] ?? 'not yet'}';
      case _SchoolRecordKind.students:
        final grade = row['grade_level'];
        final homeroom = row['homeroom']?.toString().trim();
        return '${row['student_code']} · '
            '${grade == null ? 'Grade not set' : 'Grade $grade'} · '
            '${homeroom == null || homeroom.isEmpty ? 'Homeroom not set' : 'Homeroom $homeroom'} · '
            '${row['active'] == true ? 'Active' : 'Inactive'}';
    }
  }

  Widget _buildSchoolRecordsTab() {
    return RefreshIndicator(
      onRefresh: () => _loadSchoolRecords(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'School-wide attendance records, sessions, and student records. '
            'Supabase RLS controls access; results are loaded in pages of '
            '$_pageSize.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          DropdownButton<_SchoolRecordKind>(
            value: _schoolRecordKind,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: _SchoolRecordKind.attendanceRecords,
                child: Text('Attendance records'),
              ),
              DropdownMenuItem(
                value: _SchoolRecordKind.sessions,
                child: Text('Attendance sessions'),
              ),
              DropdownMenuItem(
                value: _SchoolRecordKind.students,
                child: Text('Students'),
              ),
            ],
            onChanged: (kind) {
              if (kind == null || kind == _schoolRecordKind) return;
              setState(() {
                _schoolRecordKind = kind;
                _schoolRecordRows = [];
              });
              _loadSchoolRecords();
            },
          ),
          if (_schoolRecordsError != null)
            ListTile(
              title:
                  Text('Could not load school records: $_schoolRecordsError'),
              trailing: TextButton(
                onPressed: () => _loadSchoolRecords(
                  reset: _schoolRecordRows.isEmpty,
                ),
                child: const Text('Retry'),
              ),
            ),
          if (_loadingSchoolRecords) const LinearProgressIndicator(),
          if (!_loadingSchoolRecords && _schoolRecordRows.isEmpty)
            const ListTile(title: Text('No rows found.')),
          ..._schoolRecordRows.map(
            (row) => ListTile(
              title: Text(_schoolRecordTitle(row)),
              subtitle: Text(_schoolRecordSubtitle(row)),
              isThreeLine: true,
            ),
          ),
          if (_hasMoreSchoolRecords && _schoolRecordRows.isNotEmpty)
            Center(
              child: TextButton(
                onPressed: _loadingMoreSchoolRecords
                    ? null
                    : () => _loadSchoolRecords(reset: false),
                child: _loadingMoreSchoolRecords
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Load more rows'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAdminManagementTab() {
    final currentUserId = _client.auth.currentUser?.id;
    final staffProfiles = _adminProfiles.where(
      (profile) =>
          profile['role'] == UserRole.admin.name ||
          profile['role'] == UserRole.teacher.name,
    );
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          _loadAdminProfiles(),
          _loadCourseAssignments(),
        ]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Create staff logins, manage staff roles, and assign courses to lecturers.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _creatingStaff ? null : _createStaffLogin,
            icon: _creatingStaff
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt_1),
            label: const Text('Create Staff Login'),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Profiles & roles'),
            subtitle: Text('${staffProfiles.length} staff profile(s)'),
            trailing: IconButton(
              tooltip: 'Refresh profiles',
              onPressed: _loadingProfiles
                  ? null
                  : () => unawaited(_loadAdminProfiles()),
              icon: const Icon(Icons.refresh),
            ),
            children: [
              if (_profilesError != null)
                ListTile(
                  title: Text(
                    'Could not refresh profiles: $_profilesError'
                    '${_adminProfiles.isEmpty ? '' : '. Showing cached profiles.'}',
                  ),
                  trailing: TextButton(
                    onPressed: _loadAdminProfiles,
                    child: const Text('Retry'),
                  ),
                ),
              if (_loadingProfiles) const LinearProgressIndicator(),
              if (_adminProfiles.isEmpty && !_loadingProfiles)
                const ListTile(title: Text('No profiles are cached.')),
              ...staffProfiles.map((profile) {
                final profileId = profile['id'] as String;
                final email = profile['email'] as String;
                final isCurrentUser = profileId == currentUserId;
                final role = userRoleFromName(profile['role'] as String?);
                return ListTile(
                  title: Text(profile['full_name'] as String),
                  subtitle: Text(
                    '$email${isCurrentUser ? ' · Signed-in account' : ''}',
                  ),
                  trailing: _savingProfileIds.contains(profileId)
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : DropdownButton<UserRole>(
                          value: role,
                          hint: const Text('Unknown'),
                          items: [UserRole.admin, UserRole.teacher]
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value.name),
                                ),
                              )
                              .toList(),
                          onChanged: isCurrentUser
                              ? null
                              : (value) {
                                  if (value != null) {
                                    unawaited(
                                        _changeProfileRole(profile, value));
                                  }
                                },
                        ),
                );
              }),
              if (staffProfiles.any((row) => row['id'] == currentUserId))
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Your own role is locked here to avoid accidentally removing your admin access.',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCoursesTab() {
    return RefreshIndicator(
      onRefresh: _loadCourseAssignments,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (_loadingAssignments) const LinearProgressIndicator(),
          if (_assignmentError != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  'Could not load courses and lecturers: $_assignmentError'),
              trailing: TextButton(
                onPressed: _loadCourseAssignments,
                child: const Text('Retry'),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Assign a course',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _courseCodeController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Course code',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _courseTitleController,
                    decoration: const InputDecoration(
                      labelText: 'Course title',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedTeacherId),
                    initialValue: _selectedTeacherId,
                    decoration: const InputDecoration(
                      labelText: 'Lecturer',
                      border: OutlineInputBorder(),
                    ),
                    items: _teachers
                        .map(
                          (teacher) => DropdownMenuItem(
                            value: teacher.id,
                            child:
                                Text('${teacher.fullName} · ${teacher.email}'),
                          ),
                        )
                        .toList(),
                    onChanged: _teachers.isEmpty
                        ? null
                        : (value) => setState(() => _selectedTeacherId = value),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Initial timetable: Room TBD, Period 1, '
                    '$_defaultAcademicTerm; lecturers can update it.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _savingAssignment || _teachers.isEmpty
                        ? null
                        : _createCourseAssignment,
                    icon: _savingAssignment
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.assignment_ind_outlined),
                    label: Text(
                      _teachers.isEmpty
                          ? 'No teacher profiles available'
                          : 'Assign course',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Courses & lecturers',
              style: Theme.of(context).textTheme.titleLarge),
          if (_adminLectures.isEmpty && !_loadingAssignments)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No courses have been assigned yet.'),
            ),
          ..._adminLectures.map((lecture) {
            final teacher = _teachers.where(
              (profile) => profile.id == lecture.teacherId,
            );
            final lecturerLabel = teacher.isEmpty
                ? 'Unlisted lecturer'
                : '${teacher.first.fullName} · ${teacher.first.email}';
            return Card(
              child: ListTile(
                title: Text('${lecture.courseCode} · ${lecture.title}'),
                subtitle: Text(
                  '$lecturerLabel\n'
                  'Room ${lecture.roomNumber} · Period ${lecture.periodNumber} · '
                  '${lecture.academicTerm}',
                ),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Reassign lecturer',
                  onPressed: _teachers.isEmpty
                      ? null
                      : () => _changeLectureTeacher(lecture),
                  icon: const Icon(Icons.swap_horiz),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lectureSessionProvider);
    return DefaultTabController(
      length: 6,
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
            isScrollable: true,
            tabs: [
              Tab(text: 'Chronic Absence'),
              Tab(text: 'Teacher Logs'),
              Tab(text: 'School Settings'),
              Tab(text: 'Courses & Lecturers'),
              Tab(text: 'Admin Management'),
              Tab(text: 'School Records'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildChronicTab(),
            _buildSubmissionTab(),
            _buildSettingsTab(state),
            _buildCoursesTab(),
            _buildAdminManagementTab(),
            _buildSchoolRecordsTab(),
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

class _StaffLoginFormResult {
  final String email;
  final String password;
  final UserRole role;
  final String? fullName;
  final String? department;

  const _StaffLoginFormResult({
    required this.email,
    required this.password,
    required this.role,
    this.fullName,
    this.department,
  });
}

class _StaffLoginDialog extends StatefulWidget {
  const _StaffLoginDialog();

  @override
  State<_StaffLoginDialog> createState() => _StaffLoginDialogState();
}

class _StaffLoginDialogState extends State<_StaffLoginDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _departmentController = TextEditingController();
  UserRole _role = UserRole.teacher;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _departmentController.dispose();
    super.dispose();
  }

  String? _validEmail(String? value) {
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validPassword(String? value) {
    if ((value ?? '').length < 12) return 'Use at least 12 characters.';
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _StaffLoginFormResult(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        role: _role,
        fullName: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        department: _departmentController.text.trim().isEmpty
            ? null
            : _departmentController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Create Staff Login'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: _validEmail,
                ),
                TextFormField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Initial password',
                    helperText: 'At least 12 characters',
                  ),
                  validator: _validPassword,
                ),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name (optional)',
                  ),
                ),
                TextFormField(
                  controller: _departmentController,
                  decoration: const InputDecoration(
                    labelText: 'Department (optional)',
                  ),
                ),
                DropdownButtonFormField<UserRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: 'Staff role'),
                  items: const [UserRole.teacher, UserRole.admin]
                      .map(
                        (role) => DropdownMenuItem(
                          value: role,
                          child: Text(role.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _role = value);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _save,
            child: const Text('Create login'),
          ),
        ],
      );
}
