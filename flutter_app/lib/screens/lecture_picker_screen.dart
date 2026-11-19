import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';

class LecturePickerScreen extends ConsumerStatefulWidget {
  const LecturePickerScreen({super.key});

  @override
  ConsumerState<LecturePickerScreen> createState() =>
      _LecturePickerScreenState();
}

class _LecturePickerScreenState extends ConsumerState<LecturePickerScreen> {
  List<Lecture> _lectures = const [];
  Lecture? _selectedLecture;
  List<Student> _selectedRoster = const [];
  Object? _error;
  bool _loadingLectures = true;
  bool _loadingRoster = false;

  @override
  void initState() {
    super.initState();
    _loadLectures();
  }

  Future<void> _loadLectures() async {
    try {
      await ref.read(lectureSessionProvider.notifier).loadTeacherLectures();
      if (!mounted) return;
      setState(() {
        _lectures = ref.read(lectureSessionProvider).availableLectures;
        _loadingLectures = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLectures = false;
        _error = error;
      });
    }
  }

  Future<void> _selectLecture(Lecture lecture) async {
    setState(() {
      _selectedLecture = lecture;
      _selectedRoster = const [];
      _loadingRoster = true;
      _error = null;
    });
    try {
      final roster = await ref
          .read(lectureSessionProvider.notifier)
          .loadLectureRoster(lecture);
      if (!mounted) return;
      setState(() {
        _selectedRoster = roster;
        _loadingRoster = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingRoster = false;
        _error = error;
      });
    }
  }

  void _useSelectedLecture() {
    final lecture = _selectedLecture;
    if (lecture == null || _loadingRoster) return;
    ref
        .read(lectureSessionProvider.notifier)
        .selectLecture(lecture, _selectedRoster);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Choose a lecture')),
        body: _loadingLectures
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _lectures.isEmpty
                ? _ErrorPanel(error: _error!, onRetry: _loadLectures)
                : _lectures.isEmpty
                    ? const Center(
                        child: Text('No assigned or cached lectures found.'),
                      )
                    : Column(
                        children: [
                          Expanded(
                            child: ListView(
                              children: [
                                for (final lecture in _lectures)
                                  ListTile(
                                    selected:
                                        _selectedLecture?.id == lecture.id,
                                    title: Text(
                                      '${lecture.courseCode} · ${lecture.title}',
                                    ),
                                    subtitle: Text(
                                      'Period ${lecture.periodNumber} · '
                                      'Room ${lecture.roomNumber}',
                                    ),
                                    trailing: Icon(
                                      _selectedLecture?.id == lecture.id
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                    ),
                                    onTap: () => _selectLecture(lecture),
                                  ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      'Could not load this roster: $_error',
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (_selectedLecture != null)
                            SafeArea(
                              top: false,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _loadingRoster
                                            ? 'Loading roster…'
                                            : '${_selectedRoster.length} students cached',
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed:
                                          _loadingRoster || _error != null
                                              ? null
                                              : _useSelectedLecture,
                                      child: const Text('Use this lecture'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
      );
}

class _ErrorPanel extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorPanel({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load assigned lectures: $error'),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
