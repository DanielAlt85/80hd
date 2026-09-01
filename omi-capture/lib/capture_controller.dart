/// All the capture state and logic, with no UI in it.
///
/// The screens read this and nothing else. Previously the whole thing lived in
/// one widget's State, which was fine while the screen was a debug dump and
/// stopped being fine the moment there was more than one screen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'omi_gatt.dart';
import 'segment_writer.dart';
import 'settings.dart';
import 'uploader.dart';

void olog(String msg) {
  const chunk = 800;
  for (var i = 0; i < msg.length; i += chunk) {
    debugPrint('OMI ${msg.substring(i, (i + chunk).clamp(0, msg.length))}');
  }
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join('-').toUpperCase();

/// Starts and stops the connectedDevice foreground service, and owns the
/// notifications. Without it Android freezes this process about eleven seconds
/// after it leaves the foreground, with the link up and audio mid-stream.
class CaptureService {
  static const _channel = MethodChannel('omi_capture/service');

  static Future<void> start() => _call('start');
  static Future<void> stop() => _call('stop');

  static Future<void> update(String title, String body) =>
      _call('update', {'title': title, 'body': body});

  static Future<void> alert(String title, String body) async {
    olog('ALERT: $title — $body');
    await _call('alert', {'title': title, 'body': body});
  }

  static Future<void> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      olog('$method failed: $e');
    }
  }
}

enum LinkState { idle, scanning, connecting, connected, notFound }

/// What the pendant is doing, as far as we can tell from here.
enum PendantState {
  /// Connected, subscribed, waiting for the pendant's own detector to fire.
  listening,

  /// Audio arriving right now.
  hearing,

  /// Paused by a double press. We unsubscribe rather than discard, so the
  /// pendant stops transmitting and stops spending battery on us.
  paused,

  /// Not connected. Powered off, out of range, and flat battery all look
  /// identical from here, so this does not claim to know which.
  away,
}

class CaptureController extends ChangeNotifier {
  CaptureController(this.settings);

  Settings settings;

  final List<String> log = [];
  final _writer = SegmentWriter();
  late Uploader _uploader = Uploader(
    writer: _writer,
    log: say,
    base: Settings.normaliseUrl(settings.serverUrl),
  );

  // Link
  LinkState link = LinkState.idle;
  BluetoothDevice? _device;
  String? deviceId;
  int rssi = 0;
  int mtu = 0;
  int reconnects = 0;
  bool _linkUp = false;
  bool _stopping = false;
  bool _reconnecting = false;
  DateTime? linkSince;
  DateTime? _linkDownSince;
  String? lastDisconnectReason;

  // Pendant
  int? batteryPercent;
  bool? charging;
  String? firmware;
  String? hardware;
  int? codecId;
  int? micGain;
  int storedUnreadPackets = 0;
  int storedUsedBytes = 0;
  bool? rtcValid;
  int? lastButton;
  DateTime? pausedUntil;

  // Audio
  int packets = 0;
  int audioBytes = 0;
  int gaps = 0;
  int bursts = 0;
  int segments = 0;
  int _lastIndex = -1;
  DateTime? lastPacketAt;
  DateTime? _burstStartedAt;
  static const _burstGap = Duration(milliseconds: 500);

  // Server
  bool hostReachable = false;
  int queued = 0;
  int uploaded = 0;
  DateTime? lastUploadAt;
  DateTime? _hostDownSince;
  bool _hostAlerted = false;
  bool _linkAlerted = false;

  // Writing
  final List<(DateTime, int, List<int>)> _pending = [];
  bool _opening = false;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription> _charSubs = [];
  Timer? _statsTimer;
  Timer? _uploadTimer;
  Timer? _healthTimer;

  bool get isPaused =>
      pausedUntil != null && DateTime.now().isBefore(pausedUntil!);

  PendantState get pendantState {
    if (isPaused) return PendantState.paused;
    if (!_linkUp) return PendantState.away;
    final last = lastPacketAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 2)) {
      return PendantState.hearing;
    }
    return PendantState.listening;
  }

  String get serverBase => _uploader.base;

  void say(String s) {
    olog(s);
    log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $s');
    if (log.length > 400) log.removeLast();
    notifyListeners();
  }

  void _set(void Function() f) {
    f();
    notifyListeners();
  }

  Future<void> applySettings(Settings s) async {
    settings = s;
    await s.save();
    _uploader = Uploader(
      writer: _writer,
      log: say,
      base: Settings.normaliseUrl(s.serverUrl),
    );
    say('server set to ${_uploader.base}');
    // Probe immediately rather than making the user wait for the next tick to
    // find out whether what they typed works.
    hostReachable = await _uploader.reachable();
    notifyListeners();
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> start() async {
    _stopping = false;

    // Before scanning, not after connecting. Scanning takes forever when the
    // pendant is off, which is exactly when the phone goes in a pocket, and a
    // frozen process never reaches the line that would have saved it.
    await CaptureService.start();
    say('server ${_uploader.base}');

    _startUploadLoop();
    _startHealthLoop();

    if (!await FlutterBluePlus.isSupported) {
      _set(() => link = LinkState.idle);
      say('BLE unsupported on this device');
      return;
    }
    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      _set(() => link = LinkState.idle);
      say('bluetooth is off');
      return;
    }
    await _scan();
  }

  Future<void> restart() async {
    await stop();
    packets = audioBytes = gaps = bursts = segments = reconnects = 0;
    _lastIndex = -1;
    lastPacketAt = null;
    _burstStartedAt = null;
    log.clear();
    await start();
  }

  Future<void> stop() async {
    _stopping = true;
    _uploadTimer?.cancel();
    _healthTimer?.cancel();
    _statsTimer?.cancel();
    await _scanSub?.cancel();
    for (final s in _charSubs) {
      await s.cancel();
    }
    _charSubs.clear();
    // Always wait for the disconnect before closing. Closing early leaks a GATT
    // client; Android caps the system near thirty, and exhaustion is what
    // "error 133 for no reason" turns out to be.
    final d = _device;
    if (d != null && d.isConnected) await d.disconnect();
    await _connSub?.cancel();
    await _closeSegment();
    await CaptureService.stop();
    _set(() {
      link = LinkState.idle;
      _linkUp = false;
    });
  }

  // -------------------------------------------------------------------- link

  Future<void> _scan() async {
    _set(() => link = LinkState.scanning);
    final found = Completer<BluetoothDevice>();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        rssi = r.rssi;
        if (!found.isCompleted) found.complete(r.device);
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [OmiGatt.audioService],
      timeout: const Duration(seconds: 20),
    );

    try {
      final device = await found.future.timeout(const Duration(seconds: 20));
      await FlutterBluePlus.stopScan();
      await _connect(device);
    } on TimeoutException {
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();
      _set(() => link = LinkState.notFound);
      // Keep looking. The pendant may simply be off, and should be picked up
      // when it returns without anyone touching the app.
      if (!_stopping) {
        await Future.delayed(const Duration(seconds: 5));
        if (!_stopping) await _scan();
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    deviceId = device.remoteId.str;
    _set(() => link = LinkState.connecting);

    // A bond record is the one confirmed cause of the stuck states: it hands
    // Android a background auto-connect job and a cached service map for a
    // device that never asked to be bonded.
    if (await device.bondState.first == BluetoothBondState.bonded) {
      say('DEVICE IS BONDED — forget it in Android Bluetooth settings');
      _set(() => link = LinkState.idle);
      return;
    }

    _linkUp = false;
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) {
        _linkUp = true;
        linkSince = DateTime.now();
        _set(() => link = LinkState.connected);
        return;
      }
      // connectionState replays the current value on subscribe, before the
      // connect completes. Treating that as a drop starts a second connect flow
      // racing the first.
      if (!_linkUp) return;
      _linkUp = false;
      lastDisconnectReason = '${device.disconnectReason}';
      say('disconnected: $lastDisconnectReason');
      _set(() => link = LinkState.idle);
      if (!_stopping) _scheduleReconnect();
    });

    await device.connect(
      license: License.nonprofit,
      autoConnect: false,
      mtu: null,
    );

    _charSubs.add(device.mtu.listen((m) => _set(() => mtu = m)));
    await Future.delayed(const Duration(seconds: 3));

    // The device does not initiate the packet-size exchange, contrary to the
    // notes we started from. Left alone the link sits at 23 bytes and no audio
    // is ever sent.
    if (mtu < 100) {
      try {
        mtu = await device.requestMtu(512);
      } catch (e) {
        say('requestMtu failed: $e');
      }
    }

    await device.discoverServices();
    await _readDeviceInfo(device);
    await _syncClock(device);
    await _subscribe(device);

    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _writer.flush();
      _closeIdleBurst();
      notifyListeners();
    });
  }

  Future<void> _scheduleReconnect() async {
    if (_reconnecting || _stopping) return;
    _reconnecting = true;
    reconnects++;
    _statsTimer?.cancel();
    for (final s in _charSubs) {
      await s.cancel();
    }
    _charSubs.clear();
    await _connSub?.cancel();
    await Future.delayed(const Duration(seconds: 2));
    _reconnecting = false;
    if (!_stopping) await _scan();
  }

  BluetoothCharacteristic? _find(BluetoothDevice d, Guid s, Guid c) {
    for (final svc in d.servicesList) {
      if (svc.uuid != s) continue;
      for (final ch in svc.characteristics) {
        if (ch.uuid == c) return ch;
      }
    }
    return null;
  }

  Future<int?> _readByte(BluetoothDevice d, Guid s, Guid c) async {
    final ch = _find(d, s, c);
    if (ch == null) return null;
    try {
      final v = await ch.read().timeout(const Duration(seconds: 5));
      return v.isEmpty ? null : v.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _readDeviceInfo(BluetoothDevice d) async {
    Future<String?> str(Guid c) async {
      final ch = _find(d, OmiGatt.deviceInfoService, c);
      if (ch == null) return null;
      try {
        return String.fromCharCodes(
            await ch.read().timeout(const Duration(seconds: 5)));
      } catch (_) {
        return null;
      }
    }

    firmware = await str(OmiGatt.firmwareRevision);
    hardware = await str(OmiGatt.hardwareRevision);
    codecId = await _readByte(d, OmiGatt.audioService, OmiGatt.codecId);
    micGain = await _readByte(d, OmiGatt.settingsService, OmiGatt.micGain);
    await _readStorage(d);
    notifyListeners();
  }

  /// 16 bytes, four uint32 LE. The documented layout is for firmware >= 3.0.20
  /// and this device is 3.0.19, where the service answers anyway — so treat the
  /// numbers as indicative rather than authoritative.
  Future<void> _readStorage(BluetoothDevice d) async {
    final ch = _find(d, OmiGatt.storageService, OmiGatt.storageStatus);
    if (ch == null) return;
    try {
      final v = await ch.read().timeout(const Duration(seconds: 5));
      if (v.length < 16) return;
      final b = ByteData.sublistView(Uint8List.fromList(v));
      storedUsedBytes = b.getUint32(0, Endian.little);
      storedUnreadPackets = b.getUint32(4, Endian.little);
      rtcValid = b.getUint32(12, Endian.little) != 0;
    } catch (_) {/* indicative only; not worth surfacing a failure */}
  }

  /// Pure software clock, no battery backing. It drifts and it resets, so this
  /// happens on every connect rather than once.
  Future<void> _syncClock(BluetoothDevice d) async {
    final ch = _find(d, OmiGatt.timeService, OmiGatt.timeWrite);
    if (ch == null) return;
    final epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, epoch, Endian.little);
    try {
      await ch.write(bytes, withoutResponse: false);
    } catch (e) {
      say('clock sync failed: $e');
    }
  }

  Future<void> _subscribe(BluetoothDevice d) async {
    final battery = _find(d, OmiGatt.batteryService, OmiGatt.batteryLevel);
    if (battery != null) {
      _charSubs.add(battery.onValueReceived.listen((v) {
        if (v.isNotEmpty) _set(() => batteryPercent = v.first);
      }));
      await battery.setNotifyValue(true);
      try {
        final v = await battery.read().timeout(const Duration(seconds: 5));
        if (v.isNotEmpty) _set(() => batteryPercent = v.first);
      } catch (_) {}
    }

    final charge = _find(d, OmiGatt.settingsService, OmiGatt.charging);
    if (charge != null) {
      _charSubs.add(charge.onValueReceived.listen((v) {
        if (v.isNotEmpty) _set(() => charging = v.first != 0);
      }));
      await charge.setNotifyValue(true);
      try {
        final v = await charge.read().timeout(const Duration(seconds: 5));
        if (v.isNotEmpty) _set(() => charging = v.first != 0);
      } catch (_) {}
    }

    final button = _find(d, OmiGatt.buttonService, OmiGatt.buttonEvents);
    if (button != null) {
      _charSubs.add(button.onValueReceived.listen(_onButton));
      await button.setNotifyValue(true);
    }

    if (!isPaused) await _subscribeAudio(d);
  }

  Future<void> _subscribeAudio(BluetoothDevice d) async {
    final audio = _find(d, OmiGatt.audioService, OmiGatt.audioData);
    if (audio == null) return;
    _charSubs.add(audio.onValueReceived.listen(_onAudio));
    await audio.setNotifyValue(true);
    say('listening');
  }

  // ------------------------------------------------------------------ button

  void _onButton(List<int> v) {
    if (v.isEmpty) return;
    lastButton = v.first;
    say('button: ${ButtonEvent.describe(v.first)}');
    switch (v.first) {
      case ButtonEvent.doubleTap:
        pause(Duration(minutes: settings.pauseMinutes));
      case ButtonEvent.singleTap:
        if (isPaused) resume();
    }
    notifyListeners();
  }

  Future<void> pause(Duration d) async {
    pausedUntil = DateTime.now().add(d);
    say('paused until ${pausedUntil!.toIso8601String().substring(11, 16)}');
    // Unsubscribe rather than discard on arrival. The pendant stops
    // transmitting, which saves its battery and ours, and there is no window
    // where a packet is written to disk after the user asked us to stop.
    final d0 = _device;
    if (d0 != null) {
      final audio = _find(d0, OmiGatt.audioService, OmiGatt.audioData);
      try {
        await audio?.setNotifyValue(false);
      } catch (_) {}
    }
    await _closeSegment();
    notifyListeners();
  }

  Future<void> resume() async {
    pausedUntil = null;
    say('resumed');
    final d0 = _device;
    if (d0 != null && _linkUp) await _subscribeAudio(d0);
    notifyListeners();
  }

  // ------------------------------------------------------------------- audio

  void _onAudio(List<int> raw) {
    final p = AudioPacket.parse(raw);
    if (p == null) return;

    final now = DateTime.now();
    final since = lastPacketAt == null ? null : now.difference(lastPacketAt!);
    if (since == null || since > _burstGap) {
      bursts++;
      _burstStartedAt = now;
      _openSegment(now);
    }
    lastPacketAt = now;

    if (_opening) {
      _pending.add((now, p.index, p.opus));
    } else {
      _writer.write(now, p.index, p.opus);
    }

    packets++;
    audioBytes += p.opus.length;

    if (_lastIndex >= 0) {
      final expected = (_lastIndex + 1) & 0xFFFF;
      if (p.index != expected) gaps++;
    }
    _lastIndex = p.index;
  }

  void _openSegment(DateTime now) {
    _opening = true;
    _writer.open(now).then((_) {
      _opening = false;
      segments++;
      for (final (at, index, opus) in _pending) {
        _writer.write(at, index, opus);
      }
      _pending.clear();
    }).catchError((Object e) {
      _opening = false;
      _pending.clear();
      say('segment open failed: $e');
    });
  }

  void _closeIdleBurst() {
    final last = lastPacketAt;
    if (last == null || _burstStartedAt == null) return;
    if (DateTime.now().difference(last) > _burstGap) {
      _burstStartedAt = null;
      _closeSegment();
    }
  }

  Future<void> _closeSegment() async {
    if (!_writer.isOpen) return;
    await _writer.close();
  }

  // ------------------------------------------------------------------ server

  void _startUploadLoop() {
    _uploadTimer?.cancel();
    _uploadTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final r = await _uploader.run();
      if (!r.idle) {
        uploaded += r.uploaded;
        if (r.uploaded > 0) lastUploadAt = DateTime.now();
        notifyListeners();
      }
    });
  }

  /// Runs regardless of the Bluetooth state, unlike the stats timer. The point
  /// is to notice when the pendant is NOT connected, which is exactly when a
  /// connection-scoped timer would not be running.
  void _startHealthLoop() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      queued = (await _writer.listSegments()).length;
      hostReachable = await _uploader.reachable();
      final now = DateTime.now();

      if (isPaused == false && pausedUntil != null) await resume();

      if (hostReachable) {
        _hostDownSince = null;
        _hostAlerted = false;
      } else {
        _hostDownSince ??= now;
        if (!_hostAlerted &&
            queued > 0 &&
            now.difference(_hostDownSince!) > const Duration(minutes: 30)) {
          _hostAlerted = true;
          await CaptureService.alert(
            'Audio is not reaching the server',
            '$queued recordings waiting on the phone. '
                '${_uploader.base} has been unreachable for '
                '${now.difference(_hostDownSince!).inMinutes} minutes.',
          );
        }
      }

      if (_linkUp || isPaused) {
        _linkDownSince = null;
        _linkAlerted = false;
      } else {
        _linkDownSince ??= now;
        if (!_linkAlerted &&
            now.difference(_linkDownSince!) >
                Duration(minutes: settings.linkAlertMinutes)) {
          _linkAlerted = true;
          await CaptureService.alert(
            'Not recording',
            'The pendant has been unreachable for '
                '${now.difference(_linkDownSince!).inMinutes} minutes. It may '
                'be powered off, out of range, or its battery may be flat.',
          );
        }
      }

      await _refreshNotification();
      notifyListeners();
    });
  }

  Future<void> _refreshNotification() async {
    final title = switch (pendantState) {
      PendantState.paused => 'Paused',
      PendantState.away => 'Not connected',
      _ => 'Recording',
    };
    final parts = <String>[
      if (pendantState == PendantState.away)
        'looking for the pendant'
      else if (pendantState == PendantState.paused)
        'until ${pausedUntil!.toIso8601String().substring(11, 16)}'
      else
        '$bursts recordings',
      if (batteryPercent != null) 'pendant $batteryPercent%',
      if (queued > 0) '$queued waiting',
      if (!hostReachable) 'server unreachable',
    ];
    await CaptureService.update(title, parts.join(' · '));
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
