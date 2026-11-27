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
  Object? _lectureLoadError;
  Object? _rosterError;
  bool _loadingLectures = true;
  bool _loadingRoster = false;

  @override
  void initState() {
    super.initState();
    _loadLectures();
  }

  Future<void> _loadLectures() async {
    setState(() {
      _loadingLectures = true;
      _lectureLoadError = null;
    });
    try {
      final notifier = ref.read(lectureSessionProvider.notifier);
      await notifier.loadTeacherLectures();
      if (!mounted) return;
      setState(() {
        _lectures = ref.read(lectureSessionProvider).availableLectures;
        _loadingLectures = false;
        _lectureLoadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // The notifier publishes the SQLite cache before refreshing the cloud
        // copy, so a failed refresh can still show and use cached courses.
        _lectures = ref.read(lectureSessionProvider).availableLectures;
        _loadingLectures = false;
        _lectureLoadError = error;
        _rosterError = null;
      });
    }
  }

  Future<void> _selectLecture(Lecture lecture) async {
    setState(() {
      _selectedLecture = lecture;
      _selectedRoster = const [];
      _loadingRoster = true;
      _rosterError = null;
    });
    try {
      final notifier = ref.read(lectureSessionProvider.notifier);
      final validationError =
          await notifier.validateLectureAssignmentLocally(lecture);
      if (validationError != null) throw StateError(validationError);
      final roster = await notifier.loadLectureRoster(lecture);
      if (!mounted) return;
      setState(() {
        _selectedRoster = roster;
        _loadingRoster = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingRoster = false;
        _rosterError = error;
      });
    }
  }

  Future<void> _useSelectedLecture() async {
    final lecture = _selectedLecture;
    if (lecture == null || _loadingRoster || _rosterError != null) return;
    try {
      await ref
          .read(lectureSessionProvider.notifier)
          .selectLecture(lecture, _selectedRoster);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _rosterError = error);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Choose a lecture'),
          actions: [
            IconButton(
              tooltip: 'Refresh courses',
              onPressed: _loadingLectures ? null : _loadLectures,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _loadingLectures
            ? const Center(child: CircularProgressIndicator())
            : _lectureLoadError != null && _lectures.isEmpty
                ? _ErrorPanel(
                    error: _lectureLoadError!,
                    onRetry: _loadLectures,
                  )
                : _lectures.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'No courses have been assigned to your account by an admin yet. Contact an admin to get courses assigned.',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _loadLectures,
                                icon: const Icon(Icons.sync),
                                label: const Text('Refresh / sync courses'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              itemCount: _lectures.length +
                                  (_lectureLoadError == null ? 0 : 1),
                              itemBuilder: (context, index) {
                                if (index == _lectures.length) {
                                  return Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      'Could not refresh courses; showing the '
                                      'cached copy: $_lectureLoadError',
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  );
                                }
                                final lecture = _lectures[index];
                                return ListTile(
                                  selected: _selectedLecture?.id == lecture.id,
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
                                );
                              },
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
                                            : _rosterError != null
                                                ? 'Could not load roster: '
                                                    '$_rosterError'
                                                : '${_selectedRoster.length} students cached',
                                        style: _rosterError == null
                                            ? null
                                            : TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed:
                                          _loadingRoster || _rosterError != null
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
