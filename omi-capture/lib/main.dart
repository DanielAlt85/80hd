/// Omi capture.
///
/// Captures audio from an Omi CV1 over BLE, holds it on the phone, and forwards
/// it to a server the user chooses. The pendant runs its own voice detection, so
/// the phone stores exactly what arrives and decides nothing about it.
library;

import 'package:flutter/material.dart';

import 'capture_controller.dart';
import 'settings.dart';
import 'ui/log_page.dart';
import 'ui/settings_page.dart';
import 'ui/status_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final controller = CaptureController(settings);
  runApp(OmiApp(controller: controller));
  await controller.start();
}

class OmiApp extends StatelessWidget {
  const OmiApp({super.key, required this.controller});

  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6C8CFF),
            brightness: b,
          ),
          useMaterial3: true,
        );

    return MaterialApp(
      title: 'Omi',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: StatusPage(controller: controller),
      routes: {
        SettingsPage.route: (_) => SettingsPage(controller: controller),
        LogPage.route: (_) => LogPage(controller: controller),
      },
    );
  }
}
