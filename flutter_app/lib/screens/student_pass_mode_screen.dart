import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/attendance_models.dart';
import '../providers/lecture_guard_providers.dart';
import '../services/pass_mode_lock_service.dart';
import '../services/sync_engine_service.dart';
import '../widgets/pin_exit_dialog.dart';

class StudentPassModeScreen extends ConsumerStatefulWidget {
  final bool authGateManaged;

  const StudentPassModeScreen({
    super.key,
    this.authGateManaged = false,
  });

  @override
  ConsumerState<StudentPassModeScreen> createState() =>
      _StudentPassModeScreenState();
}

class _StudentPassModeScreenState extends ConsumerState<StudentPassModeScreen>
    with WidgetsBindingObserver {
  static const double _rowExtent = 74.0;
  static const List<String> _alphabet = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _activeJumpLetter;
  bool _unlockedForExit = false;
  bool _busy = false;
  String? _busyStudentId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _engagePassModeLock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _engagePassModeLock();
    }
  }

  Future<void> _engagePassModeLock() async {
    if (ref.read(lectureSessionProvider).activeSession?.isLockedPassMode !=
        true) {
      return;
    }
    try {
      await PassModeLockService().start();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not enable screen pinning: $error')),
        );
      }
    }
  }

  Future<void> _handleExitAttempt() async {
    final pinService = ref.read(pinSecurityProvider);
    final verified = await showAdminPinExitDialog(
      context: context,
      pinService: pinService,
    );
    if (verified && mounted) {
      try {
        await PassModeLockService().stop();
        await ref.read(lectureSessionProvider.notifier).unlockPassMode();
        if (!mounted) return;
        setState(() => _unlockedForExit = true);
        if (!widget.authGateManaged) Navigator.of(context).pop();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not unlock Pass Mode: $error')),
          );
        }
      }
    }
  }

  Future<void> _onStudentTap(Student student) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyStudentId = student.id;
    });

    try {
      final result = await ref
          .read(lectureSessionProvider.notifier)
          .checkInStudentWithBiometrics(student);

      if (!mounted) return;
      if (result.verified) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${student.displayName} verified (${result.method})'),
            backgroundColor: const Color(0xFF15803D),
            duration: const Duration(milliseconds: 1200),
          ),
        );
      } else if (result.method == 'unavailable') {
        await _offerPinProtectedCheckIn(student, result.errorMessage);
      } else if (result.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage!),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not check in ${student.displayName}: $error'),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyStudentId = null;
        });
      }
    }
  }

  Future<void> _offerPinProtectedCheckIn(
    Student student,
    String? biometricMessage,
  ) async {
    final useOverride = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Biometrics unavailable'),
        content: Text(
          biometricMessage ??
              'No biometrics are enrolled. A teacher can check in this student with the lecturer PIN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Teacher PIN'),
          ),
        ],
      ),
    );
    if (useOverride != true || !mounted) return;

    final verified = await showLecturerPinVerificationDialog(
      context: context,
      pinService: ref.read(pinSecurityProvider),
      title: 'Teacher check-in override',
      message:
          'Enter the lecturer PIN to check in ${student.displayName} without biometric verification.',
      confirmLabel: 'Verify & Check In',
    );
    if (!verified || !mounted) return;

    final sessionState = ref.read(lectureSessionProvider);
    final session = sessionState.activeSession;
    final lecture = sessionState.activeLecture;
    if (session == null || lecture == null) {
      throw StateError('There is no active attendance session.');
    }
    final elapsedMinutes =
        DateTime.now().difference(session.startedAt).inMinutes;
    final status = elapsedMinutes > lecture.lateGraceMinutes
        ? AttendanceStatus.late
        : AttendanceStatus.present;
    await ref.read(lectureSessionProvider.notifier).teacherOverrideStatus(
          student: student,
          status: status,
          reason: 'Lecturer PIN override because biometrics are unavailable.',
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${student.displayName} checked in by lecturer PIN.'),
          backgroundColor: const Color(0xFF15803D),
        ),
      );
    }
  }

  Map<String, int> _buildLetterIndexMap(List<Student> roster) {
    final map = <String, int>{};
    for (int i = 0; i < roster.length; i++) {
      final letter = roster[i].sortInitial;
      map.putIfAbsent(letter, () => i);
    }
    return map;
  }

  void _jumpToLetter(String letter, Map<String, int> letterIndexMap) {
    final index = letterIndexMap[letter];
    if (index == null || !_scrollController.hasClients) return;
    final targetOffset = (index * _rowExtent).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(targetOffset);
    setState(() => _activeJumpLetter = letter);
  }

  String _networkLabel(NetworkTransport transport) {
    switch (transport) {
      case NetworkTransport.wifi:
        return 'Wi-Fi Auto-Sync';
      case NetworkTransport.mobile:
        return 'Mobile Data Auto-Sync';
      case NetworkTransport.ethernet:
        return 'Ethernet Auto-Sync';
      case NetworkTransport.offline:
        return 'Offline (SQLite WAL)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionState = ref.watch(lectureSessionProvider);
    final lecture = sessionState.activeLecture;

    // Instant Search Filter activates dynamically at 2+ characters
    final trimmed = _searchQuery.trim().toLowerCase();
    final isFiltering = trimmed.length >= 2;
    final visibleRoster = isFiltering
        ? sessionState.roster.where((student) {
            return student.displayName.toLowerCase().contains(trimmed) ||
                student.fullName.toLowerCase().contains(trimmed) ||
                student.studentCode.toLowerCase().contains(trimmed);
          }).toList()
        : sessionState.roster;

    final letterIndexMap = _buildLetterIndexMap(visibleRoster);

    return PassModePopGuard(
      canPop: !widget.authGateManaged && _unlockedForExit,
      onBlockedPop: _handleExitAttempt,
      child: Scaffold(
        key: const Key('student-pass-mode-screen'),
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: const Color(0xFF0F172A),
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lecture?.title ?? 'Student Pass Mode',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              Text(
                'Checked In: ${sessionState.checkedInCount}/${sessionState.enrolledCount} · ${_networkLabel(sessionState.networkTransport)}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: _handleExitAttempt,
              icon: const Icon(Icons.lock_open, size: 18, color: Colors.white),
              label: const Text(
                'Admin Unlock',
                style: TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            // Instant 2+ Character Search Bar
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  hintText:
                      'Type 2+ characters to filter (${sessionState.enrolledCount} enrolled)...',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (val) => setState(() {
                  _searchQuery = val;
                  if (val.trim().length >= 2) _activeJumpLetter = null;
                }),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  // Virtualized Lazy ListView.builder with fixed itemExtent for O(1) scroll jumps
                  Expanded(
                    child: visibleRoster.isEmpty
                        ? const Center(
                            child: Text(
                              'No students match your search.',
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            itemExtent: _rowExtent,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: visibleRoster.length,
                            itemBuilder: (context, index) {
                              final student = visibleRoster[index];
                              final record =
                                  sessionState.recordsByStudentId[student.id];
                              final isLocked = record?.isLocked ?? false;
                              final isLate =
                                  record?.status == AttendanceStatus.late;

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 4),
                                child: Material(
                                  color: isLocked
                                      ? (isLate
                                          ? const Color(0xFFDCFCE7)
                                          : const Color(0xFF16A34A))
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  child: InkWell(
                                    onTap: isLocked || _busy
                                        ? null
                                        : () => _onStudentTap(student),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isLocked
                                              ? const Color(0xFF15803D)
                                              : const Color(0xFFE2E8F0),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          if (_busyStudentId == student.id)
                                            const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          else
                                            Icon(
                                              isLocked
                                                  ? Icons.verified_user
                                                  : Icons.fingerprint,
                                              color: isLocked
                                                  ? (isLate
                                                      ? const Color(0xFF15803D)
                                                      : Colors.white)
                                                  : const Color(0xFF0F172A),
                                            ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  student.fullName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color: isLocked && !isLate
                                                        ? Colors.white
                                                        : const Color(
                                                            0xFF0F172A),
                                                  ),
                                                ),
                                                Text(
                                                  isLocked
                                                      ? (isLate
                                                          ? 'Checked In · Late'
                                                          : 'Locked · Present')
                                                      : '${student.studentCode} · Gr ${student.gradeLevel}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: isLocked && !isLate
                                                        ? const Color(
                                                            0xFFDCFCE7)
                                                        : const Color(
                                                            0xFF64748B),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isLocked)
                                            Icon(
                                              Icons.lock,
                                              size: 16,
                                              color: isLate
                                                  ? const Color(0xFF15803D)
                                                  : Colors.white,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  // Vertical A-Z Quick-Jump Index Sidebar on the right
                  if (!isFiltering && visibleRoster.isNotEmpty)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: (details) {
                            final idx = ((details.localPosition.dy /
                                        constraints.maxHeight) *
                                    _alphabet.length)
                                .floor()
                                .clamp(0, _alphabet.length - 1);
                            _jumpToLetter(_alphabet[idx], letterIndexMap);
                          },
                          onVerticalDragEnd: (_) {
                            setState(() => _activeJumpLetter = null);
                          },
                          child: Container(
                            width: 32,
                            margin: const EdgeInsets.only(
                                right: 4, top: 6, bottom: 6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border:
                                  Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: _alphabet.map((letter) {
                                final hasStudents =
                                    letterIndexMap.containsKey(letter);
                                final isActive = _activeJumpLetter == letter;
                                return Expanded(
                                  child: InkWell(
                                    onTap: hasStudents
                                        ? () => _jumpToLetter(
                                            letter, letterIndexMap)
                                        : null,
                                    child: Center(
                                      child: Text(
                                        letter,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: isActive
                                              ? FontWeight.w800
                                              : FontWeight.w600,
                                          color: isActive
                                              ? const Color(0xFF16A34A)
                                              : hasStudents
                                                  ? const Color(0xFF0F172A)
                                                  : const Color(0xFFCBD5E1),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PassModePopGuard extends StatelessWidget {
  final bool canPop;
  final Future<void> Function() onBlockedPop;
  final Widget child;

  const PassModePopGuard({
    super.key,
    required this.canPop,
    required this.onBlockedPop,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, _) async {
          if (!didPop) await onBlockedPop();
        },
        child: child,
      );
}
