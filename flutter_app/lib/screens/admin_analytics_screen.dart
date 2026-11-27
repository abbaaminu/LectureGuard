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
  List<Map<String, dynamic>> _adminStudents = [];
  List<Map<String, dynamic>> _adminEnrollments = [];
  List<Map<String, dynamic>> _schoolRecordRows = [];
  _SchoolRecordKind _schoolRecordKind = _SchoolRecordKind.attendanceRecords;
  final Set<String> _savingProfileIds = {};
  final Set<String> _savingStudentIds = {};
  final Set<String> _savingEnrollmentStudentIds = {};
  String? _selectedTeacherId;
  String? _selectedEnrollmentLectureId;
  DateTime? _startDate;
  DateTime? _endDate;
  Object? _chronicError;
  Object? _logsError;
  Object? _profilesError;
  Object? _studentsError;
  Object? _enrollmentsError;
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
  bool _loadingStudents = true;
  bool _loadingEnrollments = false;
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
    await _loadCourseAssignments();
    await _loadAdminProfiles();
    await _loadAdminStudents();
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
        if (_selectedEnrollmentLectureId == null ||
            !lectures.any(
              (lecture) => lecture.id == _selectedEnrollmentLectureId,
            )) {
          _selectedEnrollmentLectureId =
              lectures.isEmpty ? null : lectures.first.id;
        }
        _loadingAssignments = false;
      });
      final lectureId = _selectedEnrollmentLectureId;
      if (lectureId != null) await _loadAdminEnrollments(lectureId);
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
        if (_selectedEnrollmentLectureId == null ||
            !cachedLectures.any(
              (lecture) => lecture.id == _selectedEnrollmentLectureId,
            )) {
          _selectedEnrollmentLectureId =
              cachedLectures.isEmpty ? null : cachedLectures.first.id;
        }
        _assignmentError = error;
        _loadingAssignments = false;
      });
      final lectureId = _selectedEnrollmentLectureId;
      if (lectureId != null) await _loadAdminEnrollments(lectureId);
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

  Future<void> _loadAdminStudents() async {
    setState(() {
      _loadingStudents = true;
      _studentsError = null;
    });
    try {
      final students = await ref
          .read(lectureSessionProvider.notifier)
          .loadAdminStudents(client: _client);
      if (!mounted) return;
      setState(() {
        _adminStudents = students;
        _loadingStudents = false;
      });
    } catch (error) {
      final cached =
          await ref.read(localDatabaseProvider).getCachedAdminStudents();
      if (!mounted) return;
      setState(() {
        _adminStudents =
            cached.map((row) => Map<String, dynamic>.from(row)).toList();
        _studentsError = error;
        _loadingStudents = false;
      });
    }
  }

  Future<void> _loadAdminEnrollments(String lectureId) async {
    setState(() {
      _loadingEnrollments = true;
      _enrollmentsError = null;
    });
    try {
      final enrollments = await ref
          .read(lectureSessionProvider.notifier)
          .loadAdminEnrollments(lectureId: lectureId, client: _client);
      if (!mounted || lectureId != _selectedEnrollmentLectureId) return;
      setState(() {
        _adminEnrollments = enrollments;
        _loadingEnrollments = false;
      });
    } catch (error) {
      final cached = await ref
          .read(localDatabaseProvider)
          .getCachedAdminEnrollments(lectureId);
      if (!mounted || lectureId != _selectedEnrollmentLectureId) return;
      setState(() {
        _adminEnrollments =
            cached.map((row) => Map<String, dynamic>.from(row)).toList();
        _enrollmentsError = error;
        _loadingEnrollments = false;
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

  Future<void> _createAdminStudent() async {
    final result = await showDialog<_AdminStudentFormResult>(
      context: context,
      builder: (_) => const _AdminStudentEditorDialog(),
    );
    if (result == null) return;
    setState(() => _loadingStudents = true);
    try {
      final student =
          await ref.read(lectureSessionProvider.notifier).createAdminStudent(
                studentCode: result.studentCode,
                firstName: result.firstName,
                lastName: result.lastName,
                gradeLevel: result.gradeLevel,
                homeroom: result.homeroom,
                client: _client,
              );
      if (!mounted) return;
      setState(() {
        _adminStudents = [..._adminStudents, student]
          ..sort(_compareAdminStudents);
        _loadingStudents = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Student created.')),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _loadingStudents = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create student: $error')),
        );
      }
    }
  }

  Future<void> _editAdminStudent(Map<String, dynamic> student) async {
    final result = await showDialog<_AdminStudentFormResult>(
      context: context,
      builder: (_) => _AdminStudentEditorDialog(student: student),
    );
    if (result == null) return;
    final studentId = student['id'] as String;
    setState(() => _savingStudentIds.add(studentId));
    try {
      final updated =
          await ref.read(lectureSessionProvider.notifier).updateAdminStudent(
                studentId: studentId,
                studentCode: result.studentCode,
                firstName: result.firstName,
                lastName: result.lastName,
                gradeLevel: result.gradeLevel,
                homeroom: result.homeroom,
                active: result.active,
                client: _client,
              );
      if (!mounted) return;
      setState(() {
        final index =
            _adminStudents.indexWhere((row) => row['id'] == studentId);
        if (index >= 0) _adminStudents[index] = updated;
        _adminStudents.sort(_compareAdminStudents);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Student updated.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update student: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingStudentIds.remove(studentId));
    }
  }

  Future<void> _linkAdminStudentAccount(Map<String, dynamic> student) async {
    final studentId = student['id'] as String;
    final currentProfileId = student['profile_id'] as String?;
    final linkedElsewhere = <String>{
      for (final other in _adminStudents)
        if (other['id'] != studentId && other['profile_id'] is String)
          other['profile_id'] as String,
    };
    final selectableProfiles = _adminProfiles
        .where(
          (profile) =>
              profile['role'] == UserRole.student.name ||
              profile['id'] == currentProfileId,
        )
        .where(
          (profile) =>
              !linkedElsewhere.contains(profile['id']) ||
              profile['id'] == currentProfileId,
        )
        .toList()
      ..sort(
        (first, second) => (first['full_name'] as String)
            .toLowerCase()
            .compareTo((second['full_name'] as String).toLowerCase()),
      );
    final selectedProfileId = await showDialog<String>(
      context: context,
      builder: (_) => _AdminStudentAccountDialog(
        studentName: '${student['first_name']} ${student['last_name']}',
        currentProfileId: currentProfileId,
        profiles: selectableProfiles,
      ),
    );
    if (selectedProfileId == null) return;
    setState(() => _savingStudentIds.add(studentId));
    try {
      final updated = await ref
          .read(lectureSessionProvider.notifier)
          .setAdminStudentProfile(
            studentId: studentId,
            profileId: selectedProfileId.isEmpty ? null : selectedProfileId,
            client: _client,
          );
      if (!mounted) return;
      setState(() {
        final index =
            _adminStudents.indexWhere((row) => row['id'] == studentId);
        if (index >= 0) _adminStudents[index] = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            selectedProfileId.isEmpty
                ? 'Student login account unlinked.'
                : 'Student login account linked.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update student account: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingStudentIds.remove(studentId));
    }
  }

  int _compareAdminStudents(
    Map<String, dynamic> first,
    Map<String, dynamic> second,
  ) =>
      (first['last_name'] as String)
          .toLowerCase()
          .compareTo((second['last_name'] as String).toLowerCase());

  Future<void> _setEnrollment(
    Map<String, dynamic> student,
    bool active,
  ) async {
    final lectureId = _selectedEnrollmentLectureId;
    if (lectureId == null) return;
    final studentId = student['id'] as String;
    setState(() => _savingEnrollmentStudentIds.add(studentId));
    try {
      await ref.read(lectureSessionProvider.notifier).setAdminEnrollment(
            lectureId: lectureId,
            studentId: studentId,
            active: active,
            client: _client,
          );
      if (!mounted) return;
      setState(() {
        final index = _adminEnrollments.indexWhere(
          (row) => row['student_id'] == studentId,
        );
        if (index < 0) {
          _adminEnrollments.add({
            'lecture_id': lectureId,
            'student_id': studentId,
            'active': active,
          });
        } else {
          _adminEnrollments[index]['active'] = active;
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not ${active ? 'enroll' : 'unenroll'} '
              '${student['first_name']} ${student['last_name']}: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _savingEnrollmentStudentIds.remove(studentId));
      }
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
        return '${row['student_code']} · Grade ${row['grade_level']} '
            '${row['homeroom']} · '
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
    final enrolledStudentIds = _adminEnrollments
        .where((row) => row['active'] == true || row['active'] == 1)
        .map((row) => row['student_id'] as String)
        .toSet();

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          _loadAdminProfiles(),
          _loadAdminStudents(),
          _loadCourseAssignments(),
        ]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Manage existing school accounts, student records, and lecture enrollment.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Create new accounts in Supabase Auth first. This screen can manage roles only for profiles that already exist; it does not create Auth users or send invitations.',
              ),
            ),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Profiles & roles'),
            subtitle: Text('${_adminProfiles.length} cached profile(s)'),
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
              ..._adminProfiles.map((profile) {
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
                          items: UserRole.values
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
              if (_adminProfiles.any((row) => row['id'] == currentUserId))
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Your own role is locked here to avoid accidentally removing your admin access.',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Students'),
            subtitle: Text('${_adminStudents.length} cached student record(s)'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Refresh students',
                  onPressed: _loadingStudents
                      ? null
                      : () => unawaited(_loadAdminStudents()),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Add student',
                  onPressed: _createAdminStudent,
                  icon: const Icon(Icons.person_add_alt_1),
                ),
              ],
            ),
            children: [
              if (_studentsError != null)
                ListTile(
                  title: Text(
                    'Could not refresh students: $_studentsError'
                    '${_adminStudents.isEmpty ? '' : '. Showing cached students.'}',
                  ),
                  trailing: TextButton(
                    onPressed: _loadAdminStudents,
                    child: const Text('Retry'),
                  ),
                ),
              if (_loadingStudents) const LinearProgressIndicator(),
              if (_adminStudents.isEmpty && !_loadingStudents)
                const ListTile(title: Text('No student records are cached.')),
              ..._adminStudents.map((student) {
                final active =
                    student['active'] == true || student['active'] == 1;
                final profileId = student['profile_id'] as String?;
                String? linkedEmail;
                if (profileId != null) {
                  for (final profile in _adminProfiles) {
                    if (profile['id'] == profileId) {
                      linkedEmail = profile['email'] as String?;
                      break;
                    }
                  }
                }
                final loginLabel = profileId == null
                    ? ' · No login linked'
                    : ' · Login: ${linkedEmail ?? 'linked'}';
                return ListTile(
                  title: Text(
                    '${student['last_name']}, ${student['first_name']}',
                  ),
                  subtitle: Text(
                    '${student['student_code']} · Grade ${student['grade_level']} · '
                    '${student['homeroom']} · ${active ? 'Active' : 'Inactive'}'
                    '$loginLabel',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: profileId == null
                            ? 'Link student login'
                            : 'Manage student login',
                        onPressed: _savingStudentIds.contains(student['id'])
                            ? null
                            : () => _linkAdminStudentAccount(student),
                        icon: Icon(
                          profileId == null
                              ? Icons.manage_accounts_outlined
                              : Icons.verified_user_outlined,
                        ),
                      ),
                      IconButton(
                        tooltip:
                            'Edit ${student['first_name']} ${student['last_name']}',
                        onPressed: _savingStudentIds.contains(student['id'])
                            ? null
                            : () => _editAdminStudent(student),
                        icon: _savingStudentIds.contains(student['id'])
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Lecture enrollment'),
            subtitle: const Text('Enroll or unenroll students in a lecture'),
            children: [
              if (_adminLectures.isEmpty)
                const ListTile(
                  title: Text(
                      'Create or load a lecture before enrolling students.'),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedEnrollmentLectureId,
                    decoration: const InputDecoration(labelText: 'Lecture'),
                    items: _adminLectures
                        .map(
                          (lecture) => DropdownMenuItem(
                            value: lecture.id,
                            child: Text(
                              '${lecture.courseCode} · ${lecture.title}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (lectureId) {
                      if (lectureId == null) return;
                      setState(() {
                        _selectedEnrollmentLectureId = lectureId;
                        _adminEnrollments = [];
                      });
                      unawaited(_loadAdminEnrollments(lectureId));
                    },
                  ),
                ),
              if (_enrollmentsError != null)
                ListTile(
                  title: Text(
                    'Could not refresh lecture enrollment: $_enrollmentsError'
                    '${_adminEnrollments.isEmpty ? '' : '. Showing cached enrollment.'}',
                  ),
                  trailing: TextButton(
                    onPressed: _selectedEnrollmentLectureId == null
                        ? null
                        : () => _loadAdminEnrollments(
                              _selectedEnrollmentLectureId!,
                            ),
                    child: const Text('Retry'),
                  ),
                ),
              if (_loadingEnrollments) const LinearProgressIndicator(),
              if (_adminLectures.isNotEmpty &&
                  !_loadingStudents &&
                  _adminStudents.isEmpty)
                const ListTile(
                  title: Text('Create student records before enrolling.'),
                ),
              ..._adminStudents.map((student) {
                final studentId = student['id'] as String;
                final activeStudent =
                    student['active'] == true || student['active'] == 1;
                final enrolled = enrolledStudentIds.contains(studentId);
                final isSaving =
                    _savingEnrollmentStudentIds.contains(studentId);
                return SwitchListTile(
                  title: Text(
                    '${student['last_name']}, ${student['first_name']}',
                  ),
                  subtitle: Text(
                    '${student['student_code']} · '
                    '${activeStudent ? 'Active student' : 'Inactive student'}',
                  ),
                  value: enrolled,
                  onChanged: isSaving || (!activeStudent && !enrolled)
                      ? null
                      : (value) => _setEnrollment(student, value),
                  secondary: isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                );
              }),
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

class _AdminStudentFormResult {
  final String studentCode;
  final String firstName;
  final String lastName;
  final int gradeLevel;
  final String homeroom;
  final bool active;

  const _AdminStudentFormResult({
    required this.studentCode,
    required this.firstName,
    required this.lastName,
    required this.gradeLevel,
    required this.homeroom,
    required this.active,
  });
}

class _AdminStudentAccountDialog extends StatefulWidget {
  final String studentName;
  final String? currentProfileId;
  final List<Map<String, dynamic>> profiles;

  const _AdminStudentAccountDialog({
    required this.studentName,
    required this.currentProfileId,
    required this.profiles,
  });

  @override
  State<_AdminStudentAccountDialog> createState() =>
      _AdminStudentAccountDialogState();
}

class _AdminStudentAccountDialogState
    extends State<_AdminStudentAccountDialog> {
  late String _selectedProfileId;

  bool get _hasCurrentProfile =>
      widget.currentProfileId != null &&
      widget.profiles.any(
        (profile) => profile['id'] == widget.currentProfileId,
      );

  @override
  void initState() {
    super.initState();
    _selectedProfileId = _hasCurrentProfile
        ? widget.currentProfileId!
        : widget.currentProfileId ?? '';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Student login account'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Link ${widget.studentName} to the Supabase login used for '
                'student self-service attendance. Only profiles with the '
                'student role are listed.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedProfileId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Login account',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('No linked account'),
                  ),
                  if (widget.currentProfileId != null && !_hasCurrentProfile)
                    DropdownMenuItem(
                      value: widget.currentProfileId!,
                      child: Text(
                        'Current linked account '
                        '(${widget.currentProfileId})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ...widget.profiles.map(
                    (profile) => DropdownMenuItem(
                      value: profile['id'] as String,
                      child: Text(
                        '${profile['full_name']} · ${profile['email']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedProfileId = value);
                  }
                },
              ),
              if (widget.profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'No unlinked student accounts are available. Provision the '
                    'account and set its profile role to Student first.',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _selectedProfileId),
            child: const Text('Save'),
          ),
        ],
      );
}

class _AdminStudentEditorDialog extends StatefulWidget {
  final Map<String, dynamic>? student;

  const _AdminStudentEditorDialog({this.student});

  @override
  State<_AdminStudentEditorDialog> createState() =>
      _AdminStudentEditorDialogState();
}

class _AdminStudentEditorDialogState extends State<_AdminStudentEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _gradeController;
  late final TextEditingController _homeroomController;
  late bool _active;

  @override
  void initState() {
    super.initState();
    final student = widget.student;
    _codeController =
        TextEditingController(text: student?['student_code'] as String? ?? '');
    _firstNameController =
        TextEditingController(text: student?['first_name'] as String? ?? '');
    _lastNameController =
        TextEditingController(text: student?['last_name'] as String? ?? '');
    _gradeController = TextEditingController(
      text: student == null ? '' : '${student['grade_level']}',
    );
    _homeroomController =
        TextEditingController(text: student?['homeroom'] as String? ?? '');
    _active =
        student == null || student['active'] == true || student['active'] == 1;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _gradeController.dispose();
    _homeroomController.dispose();
    super.dispose();
  }

  String? _required(String? value, String label) =>
      value == null || value.trim().isEmpty ? '$label is required.' : null;

  String? _validateGrade(String? value) {
    final grade = int.tryParse(value ?? '');
    if (grade == null || grade < 9 || grade > 12) {
      return 'Enter a grade from 9 to 12.';
    }
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _AdminStudentFormResult(
        studentCode: _codeController.text.trim(),
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        gradeLevel: int.parse(_gradeController.text),
        homeroom: _homeroomController.text.trim(),
        active: _active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.student == null ? 'Add student' : 'Edit student'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _codeController,
                  decoration: const InputDecoration(labelText: 'Student code'),
                  validator: (value) => _required(value, 'Student code'),
                ),
                TextFormField(
                  controller: _firstNameController,
                  decoration: const InputDecoration(labelText: 'First name'),
                  validator: (value) => _required(value, 'First name'),
                ),
                TextFormField(
                  controller: _lastNameController,
                  decoration: const InputDecoration(labelText: 'Last name'),
                  validator: (value) => _required(value, 'Last name'),
                ),
                TextFormField(
                  controller: _gradeController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Grade (9-12)'),
                  validator: _validateGrade,
                ),
                TextFormField(
                  controller: _homeroomController,
                  decoration: const InputDecoration(labelText: 'Homeroom'),
                  validator: (value) => _required(value, 'Homeroom'),
                ),
                if (widget.student != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active student'),
                    value: _active,
                    onChanged: (value) => setState(() => _active = value),
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
            child: Text(widget.student == null ? 'Create student' : 'Save'),
          ),
        ],
      );
}
