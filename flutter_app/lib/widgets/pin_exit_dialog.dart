import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/pin_security_service.dart';

Future<bool> showAdminPinExitDialog({
  required BuildContext context,
  required PinSecurityService pinService,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinExitDialog(pinService: pinService),
  );
  return result ?? false;
}

class _PinExitDialog extends StatefulWidget {
  final PinSecurityService pinService;

  const _PinExitDialog({required this.pinService});

  @override
  State<_PinExitDialog> createState() => _PinExitDialogState();
}

class _PinExitDialogState extends State<_PinExitDialog> {
  final _pinController = TextEditingController();
  String? _errorText;
  bool _verifying = false;
  int _failedAttempts = 0;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    final pin = _pinController.text.trim();
    if (pin.length != 4) {
      setState(() => _errorText = 'Enter your 4-digit lecturer PIN.');
      return;
    }

    setState(() {
      _verifying = true;
      _errorText = null;
    });

    final valid = await widget.pinService.verifyLecturerPin(pin);
    if (!mounted) return;

    if (valid) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _verifying = false;
        _failedAttempts += 1;
        _pinController.clear();
        _errorText = 'Incorrect PIN (Attempt $_failedAttempts). Pass Mode remains locked.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: Color(0xFF0F172A)),
          SizedBox(width: 10),
          Text('Lecturer PIN Required'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Student Pass Mode is locked to prevent unauthorized exit. Enter the 4-digit lecturer PIN to unlock.',
            style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pinController,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 14,
              fontWeight: FontWeight.w700,
            ),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••',
              errorText: _errorText,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => _submitPin(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.of(context).pop(false),
          child: const Text('Stay in Pass Mode'),
        ),
        FilledButton(
          onPressed: _verifying ? null : _submitPin,
          child: _verifying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Unlock & Exit'),
        ),
      ],
    );
  }
}
