import 'package:flutter/material.dart';

import '../capture_controller.dart';
import '../settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  static const route = '/settings';
  final CaptureController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _url =
      TextEditingController(text: widget.controller.settings.serverUrl);
  late int _pause = widget.controller.settings.pauseMinutes;
  late int _alert = widget.controller.settings.linkAlertMinutes;

  String? _urlError;
  bool _testing = false;
  bool? _testResult;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final err = Settings.validateUrl(_url.text);
    setState(() {
      _urlError = err;
      _testResult = null;
    });
    if (err != null) return;

    setState(() => _testing = true);
    // Apply before testing rather than after. Testing a URL the app is not
    // actually using would prove nothing about whether uploads will work.
    await widget.controller.applySettings(Settings(
      serverUrl: Settings.normaliseUrl(_url.text),
      pauseMinutes: _pause,
      linkAlertMinutes: _alert,
    ));
    setState(() {
      _testing = false;
      _testResult = widget.controller.hostReachable;
    });
  }

  Future<void> _save() async {
    final err = Settings.validateUrl(_url.text);
    if (err != null) {
      setState(() => _urlError = err);
      return;
    }
    await widget.controller.applySettings(Settings(
      serverUrl: Settings.normaliseUrl(_url.text),
      pauseMinutes: _pause,
      linkAlertMinutes: _alert,
    ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Server', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Where recordings are sent',
              hintText: 'https://your-machine.tailnet.ts.net',
              border: const OutlineInputBorder(),
              errorText: _urlError,
              helperText: 'A Tailscale Serve address works from any network '
                  'without opening a port.',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {
              _urlError = null;
              _testResult = null;
            }),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _testing ? null : _test,
                child: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Test connection'),
              ),
              const SizedBox(width: 12),
              if (_testResult != null)
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        _testResult! ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: _testResult!
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _testResult! ? 'Reachable' : 'No answer',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          // Nothing is lost while the server is unreachable. Worth saying here,
          // because an unreachable server looks alarming and mostly is not.
          const SizedBox(height: 8),
          Text(
            'Recordings are kept on the phone until the server confirms it has '
            'them, so changing this — or having it unreachable for a while — '
            'does not lose anything.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 40),

          Text('Pause', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text('Double press the pendant to pause. Single press resumes.',
              style: Theme.of(context).textTheme.bodySmall),
          _Stepper(
            label: 'Pause lasts',
            value: _pause,
            unit: 'minutes',
            options: const [15, 30, 60, 120, 240],
            onChanged: (v) => setState(() => _pause = v),
          ),
          const Divider(height: 40),

          Text('Alerts', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text('How long the pendant can be missing before the app says so.',
              style: Theme.of(context).textTheme.bodySmall),
          _Stepper(
            label: 'Warn after',
            value: _alert,
            unit: 'minutes',
            options: const [2, 5, 10, 30, 60],
            onChanged: (v) => setState(() => _alert = v),
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.unit,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final int value;
  final String unit;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<int>(
            value: options.contains(value) ? value : options.first,
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text('$o $unit')),
            ],
            onChanged: (v) => v == null ? null : onChanged(v),
          ),
        ],
      ),
    );
  }
}
