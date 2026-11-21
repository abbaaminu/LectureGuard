import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pin_security_service.dart';

class LecturerPinSetupScreen extends StatefulWidget {
  final PinSecurityService pinService;
  final VoidCallback? onConfigured;

  const LecturerPinSetupScreen({
    super.key,
    required this.pinService,
    this.onConfigured,
  });

  @override
  State<LecturerPinSetupScreen> createState() => _LecturerPinSetupScreenState();
}

class _LecturerPinSetupScreenState extends State<LecturerPinSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _errorText;
  bool _saving = false;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    final pin = _pinController.text;
    final validationError = PinSecurityService.validatePin(pin);
    if (validationError != null) {
      setState(() => _errorText = validationError);
      return;
    }
    if (pin != _confirmController.text) {
      setState(() => _errorText = 'The PIN entries do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await widget.pinService.setLecturerPin(pin);
      if (!mounted) return;
      final onConfigured = widget.onConfigured;
      if (onConfigured != null) {
        onConfigured();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorText = 'Could not save PIN: $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Text('Set lecturer PIN'),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Create a private 4-digit PIN. It is required to exit Student Pass Mode and change this PIN.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      key: const Key('pin-setup-new'),
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'New lecturer PIN',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('pin-setup-confirm'),
                      controller: _confirmController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Confirm lecturer PIN',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _savePin(),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorText!,
                        key: const Key('pin-setup-error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('pin-setup-save'),
                      onPressed: _saving ? null : _savePin,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save PIN'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
