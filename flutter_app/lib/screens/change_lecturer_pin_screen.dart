import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pin_security_service.dart';

class ChangeLecturerPinScreen extends StatefulWidget {
  final PinSecurityService pinService;

  const ChangeLecturerPinScreen({
    super.key,
    required this.pinService,
  });

  @override
  State<ChangeLecturerPinScreen> createState() =>
      _ChangeLecturerPinScreenState();
}

class _ChangeLecturerPinScreenState extends State<ChangeLecturerPinScreen> {
  final _oldPinController = TextEditingController();
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  String? _errorText;
  bool _saving = false;

  @override
  void dispose() {
    _oldPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _changePin() async {
    final newPin = _newPinController.text;
    final validationError = PinSecurityService.validatePin(newPin);
    if (validationError != null) {
      setState(() => _errorText = validationError);
      return;
    }
    if (newPin != _confirmPinController.text) {
      setState(() => _errorText = 'The new PIN entries do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      final changed = await widget.pinService.changeLecturerPin(
        oldPin: _oldPinController.text,
        newPin: newPin,
      );
      if (!mounted) return;
      if (changed) {
        Navigator.of(context).pop(true);
        return;
      }

      final lockout = await widget.pinService.getLockoutStatus();
      setState(() {
        _saving = false;
        _errorText = lockout.remaining == null
            ? 'The current PIN is incorrect.'
            : 'Too many attempts. Try again in '
                '${_remainingSeconds(lockout.remaining!)} seconds.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorText = 'Could not change PIN: $error';
        });
      }
    }
  }

  int _remainingSeconds(Duration remaining) =>
      (remaining.inMilliseconds / 1000).ceil();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change lecturer PIN')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                  key: const Key('pin-change-old'),
                  controller: _oldPinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Current PIN',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                  const SizedBox(height: 12),
                  TextField(
                  key: const Key('pin-change-new'),
                  controller: _newPinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'New PIN',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                  const SizedBox(height: 12),
                  TextField(
                  key: const Key('pin-change-confirm'),
                  controller: _confirmPinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Confirm new PIN',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _changePin(),
                ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorText!,
                      key: const Key('pin-change-error'),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('pin-change-submit'),
                    onPressed: _saving ? null : _changePin,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Change PIN'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
