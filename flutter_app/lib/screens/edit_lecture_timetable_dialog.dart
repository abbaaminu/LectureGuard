import 'package:flutter/material.dart';
import '../models/attendance_models.dart';

class LectureTimetableUpdate {
  final String roomNumber;
  final int periodNumber;
  final String academicTerm;
  final int lateGraceMinutes;

  const LectureTimetableUpdate({
    required this.roomNumber,
    required this.periodNumber,
    required this.academicTerm,
    required this.lateGraceMinutes,
  });
}

class EditLectureTimetableDialog extends StatefulWidget {
  final Lecture lecture;

  const EditLectureTimetableDialog({super.key, required this.lecture});

  @override
  State<EditLectureTimetableDialog> createState() =>
      _EditLectureTimetableDialogState();
}

class _EditLectureTimetableDialogState
    extends State<EditLectureTimetableDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _roomController;
  late final TextEditingController _periodController;
  late final TextEditingController _termController;
  late final TextEditingController _graceController;

  @override
  void initState() {
    super.initState();
    _roomController = TextEditingController(text: widget.lecture.roomNumber);
    _periodController =
        TextEditingController(text: widget.lecture.periodNumber.toString());
    _termController = TextEditingController(text: widget.lecture.academicTerm);
    _graceController =
        TextEditingController(text: widget.lecture.lateGraceMinutes.toString());
  }

  @override
  void dispose() {
    _roomController.dispose();
    _periodController.dispose();
    _termController.dispose();
    _graceController.dispose();
    super.dispose();
  }

  String? _requiredText(String? value, String field) =>
      value == null || value.trim().isEmpty ? '$field is required.' : null;

  String? _positiveInteger(String? value, String field,
      {bool allowZero = false, int? maximum}) {
    final number = int.tryParse(value ?? '');
    if (number == null || number < (allowZero ? 0 : 1)) {
      return 'Enter a valid $field.';
    }
    if (maximum != null && number > maximum) {
      return '$field must be $maximum or less.';
    }
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      LectureTimetableUpdate(
        roomNumber: _roomController.text.trim(),
        periodNumber: int.parse(_periodController.text),
        academicTerm: _termController.text.trim(),
        lateGraceMinutes: int.parse(_graceController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Update timetable'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${widget.lecture.courseCode} · ${widget.lecture.title}',
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _roomController,
                  decoration: const InputDecoration(labelText: 'Room'),
                  validator: (value) => _requiredText(value, 'Room'),
                ),
                TextFormField(
                  controller: _periodController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Period'),
                  // `002_fix_rls_and_views.sql` relaxes the original 1-10
                  // constraint to `period_number >= 1`; the remaining hard
                  // limit is the SMALLINT column, which a queued edit cannot
                  // exceed without failing at sync time.
                  validator: (value) => _positiveInteger(
                    value,
                    'period number',
                    maximum: 32767,
                  ),
                ),
                TextFormField(
                  controller: _termController,
                  decoration: const InputDecoration(labelText: 'Academic term'),
                  validator: (value) => _requiredText(value, 'Academic term'),
                ),
                TextFormField(
                  controller: _graceController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Late grace (minutes)'),
                  validator: (value) => _positiveInteger(
                    value,
                    'late grace time',
                    allowZero: true,
                    maximum: 32767,
                  ),
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
          FilledButton(onPressed: _save, child: const Text('Save timetable')),
        ],
      );
}
