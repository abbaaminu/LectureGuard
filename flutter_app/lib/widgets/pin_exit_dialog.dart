import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pin_security_service.dart';

Future<bool> showAdminPinExitDialog({
  required BuildContext context,
  required PinSecurityService pinService,
}) =>
    showLecturerPinVerificationDialog(
      context: context,
      pinService: pinService,
    );

Future<bool> showLecturerPinVerificationDialog({
  required BuildContext context,
  required PinSecurityService pinService,
  String title = 'Lecturer PIN Required',
  String message =
      'Student Pass Mode is locked to prevent unauthorized exit. Enter the 4-digit lecturer PIN to unlock.',
  String confirmLabel = 'Verify PIN',
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinExitDialog(
      pinService: pinService,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
  return result ?? false;
}

class _PinExitDialog extends StatefulWidget {
  final PinSecurityService pinService;
  final String title;
  final String message;
  final String confirmLabel;

  const _PinExitDialog({
    required this.pinService,
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  @override
  State<_PinExitDialog> createState() => _PinExitDialogState();
}

class _PinExitDialogState extends State<_PinExitDialog> {
  final _pinController = TextEditingController();
  Timer? _countdownTimer;
  String? _errorText;
  Duration? _lockoutRemaining;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _refreshLockout();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshLockout(),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _refreshLockout() async {
    try {
      final status = await widget.pinService.getLockoutStatus();
      if (!mounted) return;
      setState(() {
        _lockoutRemaining = status.remaining;
        if (status.remaining == null &&
            _errorText?.startsWith('Too many attempts') == true) {
          _errorText = null;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _errorText = 'Could not check PIN lockout: $error');
      }
    }
  }

  Future<void> _submitPin() async {
    if (_verifying || _lockoutRemaining != null) return;
    final pin = _pinController.text.trim();
    if (pin.length != 4) {
      setState(() => _errorText = 'Enter your 4-digit lecturer PIN.');
      return;
    }

    setState(() {
      _verifying = true;
      _errorText = null;
    });

    try {
      final valid = await widget.pinService.verifyLecturerPin(pin);
      if (!mounted) return;
      if (valid) {
        Navigator.of(context).pop(true);
        return;
      }

      final status = await widget.pinService.getLockoutStatus();
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _lockoutRemaining = status.remaining;
        _pinController.clear();
        _errorText = status.remaining != null
            ? 'Too many attempts. Pass Mode remains locked.'
            : 'Incorrect PIN (${status.failedAttempts}/5 attempts). Pass Mode remains locked.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _verifying = false;
          _errorText = 'Could not verify lecturer PIN: $error';
        });
      }
    }
  }

  int get _remainingSeconds =>
      (_lockoutRemaining!.inMilliseconds / 1000).ceil();

  @override
  Widget build(BuildContext context) {
    final lockedOut = _lockoutRemaining != null;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lock_outline, color: Color(0xFF0F172A)),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('lecturer-pin-input'),
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
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => _submitPin(),
          ),
          if (lockedOut) ...[
            const SizedBox(height: 8),
            Text(
              'PIN locked for $_remainingSeconds seconds.',
              key: const Key('pin-lockout-countdown'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('lecturer-pin-submit'),
          onPressed: _verifying || lockedOut ? null : _submitPin,
          child: _verifying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
