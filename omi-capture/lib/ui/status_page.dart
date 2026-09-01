import 'package:flutter/material.dart';

import '../capture_controller.dart';
import 'log_page.dart';
import 'settings_page.dart';

/// What is the pendant doing, is it going to keep doing it, and is any of it
/// getting off the phone. Everything else belongs behind the log screen.
class StatusPage extends StatelessWidget {
  const StatusPage({super.key, required this.controller});

  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final c = controller;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Omi'),
            actions: [
              IconButton(
                icon: const Icon(Icons.terminal),
                tooltip: 'Log',
                onPressed: () =>
                    Navigator.pushNamed(context, LogPage.route),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () =>
                    Navigator.pushNamed(context, SettingsPage.route),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: c.restart,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _PendantCard(c: c),
                const SizedBox(height: 12),
                _DeviceCard(c: c),
                const SizedBox(height: 12),
                _ServerCard(c: c),
                const SizedBox(height: 12),
                _SessionCard(c: c),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PendantCard extends StatelessWidget {
  const _PendantCard({required this.c});
  final CaptureController c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, String title, String detail, Color tint) =
        switch (c.pendantState) {
      PendantState.hearing => (
          Icons.graphic_eq,
          'Hearing you',
          'Recording right now',
          scheme.primary,
        ),
      PendantState.listening => (
          Icons.hearing,
          'Listening',
          'Waiting for someone to speak',
          scheme.primary,
        ),
      PendantState.paused => (
          Icons.pause_circle_outline,
          'Paused',
          c.pausedUntil == null
              ? 'Paused'
              : 'Until ${_hhmm(c.pausedUntil!)} · single press to resume',
          scheme.tertiary,
        ),
      PendantState.away => (
          Icons.podcasts,
          switch (c.link) {
            LinkState.scanning => 'Looking for your Omi',
            LinkState.connecting => 'Connecting',
            LinkState.notFound => 'Can\'t find your Omi',
            _ => 'Not connected',
          },
          // Deliberately does not guess. A three second hold powers the pendant
          // off and sends nothing, so off, out of range, and flat battery are
          // indistinguishable from here.
          c.link == LinkState.notFound
              ? 'It may be off, out of range, or out of battery'
              : 'Searching',
          scheme.error,
        ),
    };

    return Card(
      elevation: 0,
      color: tint.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 34, color: tint),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text(detail,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: Icon(c.isPaused
                        ? Icons.play_arrow
                        : Icons.pause_outlined),
                    label: Text(c.isPaused
                        ? 'Resume'
                        : 'Pause ${c.settings.pauseMinutes}m'),
                    onPressed: c.link == LinkState.connected || c.isPaused
                        ? () => c.isPaused
                            ? c.resume()
                            : c.pause(
                                Duration(minutes: c.settings.pauseMinutes))
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.c});
  final CaptureController c;

  @override
  Widget build(BuildContext context) {
    final battery = c.batteryPercent;
    return _Section(
      title: 'Your Omi',
      children: [
        _Row(
          icon: battery == null
              ? Icons.battery_unknown
              : (c.charging == true
                  ? Icons.battery_charging_full
                  : _batteryIcon(battery)),
          label: 'Battery',
          value: battery == null
              ? 'unknown'
              : '$battery%${c.charging == true ? ' · charging' : ''}',
          warn: battery != null && battery < 20 && c.charging != true,
        ),
        _Row(
          icon: Icons.sd_storage_outlined,
          label: 'On the pendant',
          // The documented field layout is for firmware >= 3.0.20 and this one
          // is older, so this is shown as indicative rather than as a fact.
          value: c.storedUnreadPackets == 0
              ? 'nothing waiting'
              : '~${c.storedUnreadPackets} unread',
        ),
        if (c.firmware != null)
          _Row(
            icon: Icons.memory,
            label: 'Firmware',
            value: 'v${c.firmware}'
                '${c.hardware != null ? ' · hw ${c.hardware}' : ''}',
          ),
        if (c.link == LinkState.connected)
          _Row(
            icon: Icons.bluetooth_connected,
            label: 'Signal',
            value: '${c.rssi} dBm',
          ),
      ],
    );
  }

  IconData _batteryIcon(int pct) => switch (pct) {
        >= 90 => Icons.battery_full,
        >= 60 => Icons.battery_5_bar,
        >= 40 => Icons.battery_3_bar,
        >= 20 => Icons.battery_2_bar,
        _ => Icons.battery_alert,
      };
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.c});
  final CaptureController c;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Server',
      trailing: TextButton(
        onPressed: () => Navigator.pushNamed(context, SettingsPage.route),
        child: const Text('Change'),
      ),
      children: [
        _Row(
          icon: c.hostReachable ? Icons.cloud_done_outlined : Icons.cloud_off,
          label: c.hostReachable ? 'Connected' : 'Unreachable',
          value: Uri.tryParse(c.serverBase)?.host ?? c.serverBase,
          warn: !c.hostReachable,
        ),
        if (!c.hostReachable && c.serverError != null)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: Text(
              c.serverError!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
        _Row(
          icon: Icons.upload_outlined,
          label: 'Waiting to send',
          value: c.queued == 0 ? 'nothing' : '${c.queued} recordings',
          warn: c.queued > 20,
        ),
        _Row(
          icon: Icons.check_circle_outline,
          label: 'Sent',
          value: '${c.uploaded}'
              '${c.lastUploadAt != null ? ' · last ${_hhmm(c.lastUploadAt!)}' : ''}',
        ),
      ],
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.c});
  final CaptureController c;

  @override
  Widget build(BuildContext context) {
    final minutes = (c.packets * 20 / 1000 / 60);
    return _Section(
      title: 'Since the app started',
      children: [
        _Row(
          icon: Icons.mic_none,
          label: 'Recordings',
          value: '${c.bursts}',
        ),
        _Row(
          icon: Icons.schedule,
          label: 'Audio captured',
          value: minutes < 1
              ? '${(c.packets * 20 / 1000).toStringAsFixed(0)}s'
              : '${minutes.toStringAsFixed(1)} min',
        ),
        if (c.gaps > 0)
          _Row(
            icon: Icons.warning_amber_outlined,
            label: 'Dropped packets',
            value: '${c.gaps}',
            warn: true,
          ),
        if (c.reconnects > 0)
          _Row(
            icon: Icons.autorenew,
            label: 'Reconnects',
            value: '${c.reconnects}',
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ furniture

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )),
                ?trailing,
              ],
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final valueStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: warn ? scheme.error : scheme.onSurfaceVariant,
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20,
              color: warn ? scheme.error : scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          // Both sides are flexible with fixed proportions. Letting the value
          // size itself and giving the label the remainder squeezed "Battery"
          // down to one character per line the moment a value got long, and a
          // hostname overflowed the row entirely.
          Expanded(flex: 4, child: Text(label)),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
