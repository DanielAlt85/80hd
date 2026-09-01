import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture_controller.dart';

/// The old debug dump, kept but moved out of the way. It is genuinely useful
/// when something is wrong and pure noise the rest of the time.
class LogPage extends StatelessWidget {
  const LogPage({super.key, required this.controller});

  static const route = '/log';
  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final lines = controller.log;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Log'),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: 'Copy',
                onPressed: lines.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(
                            ClipboardData(text: lines.join('\n')));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Log copied')),
                        );
                      },
              ),
              IconButton(
                icon: const Icon(Icons.restart_alt),
                tooltip: 'Restart capture',
                onPressed: controller.restart,
              ),
            ],
          ),
          body: lines.isEmpty
              ? const Center(child: Text('Nothing logged yet.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: SelectableText(
                      lines[i],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11.5),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
