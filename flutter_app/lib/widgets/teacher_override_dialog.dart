import 'package:flutter/material.dart';
import '../models/attendance_models.dart';

class TeacherOverrideRequest {
  final AttendanceStatus status;
  final String? reason;

  const TeacherOverrideRequest({required this.status, this.reason});
}

class TeacherOverrideDialog extends StatefulWidget {
  final String studentName;
  final AttendanceStatus initialStatus;
  final bool overridingBiometricCheckIn;

  const TeacherOverrideDialog({
    super.key,
    required this.studentName,
    required this.initialStatus,
    required this.overridingBiometricCheckIn,
  });

  @override
  State<TeacherOverrideDialog> createState() => _TeacherOverrideDialogState();
}

class _TeacherOverrideDialogState extends State<TeacherOverrideDialog> {
  late AttendanceStatus _status = widget.initialStatus;
  final _reasonController = TextEditingController();
  bool _showReasonError = false;

  bool get _requiresReason =>
      _status == AttendanceStatus.excused ||
      _status == AttendanceStatus.absent ||
      widget.overridingBiometricCheckIn;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _save() {
    final reason = _reasonController.text.trim();
    if (_requiresReason && reason.isEmpty) {
      setState(() => _showReasonError = true);
      return;
    }
    Navigator.of(context).pop(
      TeacherOverrideRequest(
        status: _status,
        reason: reason.isEmpty ? null : reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Override ${widget.studentName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<AttendanceStatus>(
              groupValue: _status,
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _status = value;
                    _showReasonError = false;
                  });
                }
              },
              child: Column(
                children: [
                  for (final status in AttendanceStatus.values)
                    RadioListTile<AttendanceStatus>(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        status.name[0].toUpperCase() + status.name.substring(1),
                      ),
                      value: status,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonController,
              maxLength: 240,
              decoration: InputDecoration(
                labelText: _requiresReason ? 'Reason (required)' : 'Reason (optional)',
                border: const OutlineInputBorder(),
                errorText: _showReasonError ? 'Enter a reason to continue.' : null,
              ),
              onChanged: (_) {
                if (_showReasonError) setState(() => _showReasonError = false);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
