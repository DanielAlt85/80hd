/// Phase 0/1 probe for the Omi CV1.
///
/// This is deliberately verbose. Everything it learns goes to logcat so it can
/// be read over adb without anyone watching the screen:
///
///   adb logcat -s flutter:V | grep OMI
///
/// What it proves, in order: that we can find the device by service UUID alone,
/// connect without bonding, sync the clock, let the device drive the packet-size
/// negotiation, and receive audio and button notifications with the packet
/// indices intact.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'omi_gatt.dart';

void main() => runApp(const ProbeApp());

/// logcat is line-oriented and drops very long lines, so chunk.
void olog(String msg) {
  const chunk = 800;
  for (var i = 0; i < msg.length; i += chunk) {
    debugPrint('OMI ${msg.substring(i, (i + chunk).clamp(0, msg.length))}');
  }
}

/// Starts and stops the connectedDevice foreground service. Without it Android
/// freezes this process about eleven seconds after it leaves the foreground,
/// mid-stream, connection still open.
class CaptureService {
  static const _channel = MethodChannel('omi_capture/service');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
      olog('foreground service started');
    } catch (e) {
      olog('foreground service failed to start: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
      olog('foreground service stopped');
    } catch (e) {
      olog('foreground service failed to stop: $e');
    }
  }
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join('-').toUpperCase();

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'omi capture probe',
        theme: ThemeData.dark(useMaterial3: true),
        home: const ProbePage(),
      );
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final List<String> _lines = [];
  String _status = 'idle';

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription> _charSubs = [];
  Timer? _statsTimer;

  // Running audio statistics. The gap count is the number that matters: a
  // non-sequential packet index means a dropped packet, and the gap has to
  // reach the transcript so sentences do not silently weld together.
  int _packets = 0;
  int _audioBytes = 0;
  int _gaps = 0;
  int _lastIndex = -1;
  int _lastButton = -1;
  int _mtu = 0;

  // The device runs its own voice activity detection: it sends nothing at all
  // during silence, and the packet index keeps counting straight through the
  // gap. So the protocol gives us no way to tell a one-second pause from a
  // twenty-minute one — only arrival time does. Every packet gets stamped on
  // receipt, and a burst boundary is inferred from the delta.
  DateTime? _lastPacketAt;
  DateTime? _burstStartedAt;
  int _bursts = 0;
  static const _burstGap = Duration(milliseconds: 500);

  // Reconnect state. _stopping distinguishes "the link dropped" from "we are
  // shutting down on purpose" — without it, tearing the page down would kick
  // off a reconnect against a device we just chose to let go.
  bool _stopping = false;
  bool _reconnecting = false;
  int _reconnects = 0;

  // connectionState replays the current value on subscribe, which is
  // "disconnected" because the connection has not completed yet. Treating that
  // as a dropped link starts a second connect flow racing the first. Only a
  // disconnect that follows an actual connected event counts.
  bool _linkUp = false;

  void _say(String s) {
    olog(s);
    if (!mounted) return;
    setState(() {
      _lines.insert(0, s);
      if (_lines.length > 300) _lines.removeLast();
    });
  }

  void _setStatus(String s) {
    olog('STATUS $s');
    if (mounted) setState(() => _status = s);
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  Future<void> _start() async {
    // No runtime permission prompt here on purpose. permission_handler requires
    // compileSdk 37, which Google's own tooling cannot currently install in a
    // form Gradle resolves. For a debug probe driven over adb the permissions
    // are granted directly:
    //
    //   adb shell pm grant com.danielalt.omi_capture android.permission.BLUETOOTH_SCAN
    //   adb shell pm grant com.danielalt.omi_capture android.permission.BLUETOOTH_CONNECT
    //
    // The shipping app needs a real prompt. Revisit once API 37 installs cleanly.
    _setStatus('starting');

    if (!await FlutterBluePlus.isSupported) {
      _setStatus('BLE unsupported on this device');
      return;
    }
    final adapter = await FlutterBluePlus.adapterState.first;
    _say('adapter state: $adapter');
    if (adapter != BluetoothAdapterState.on) {
      _setStatus('bluetooth is off');
      return;
    }

    await _scan();
  }

  Future<void> _scan() async {
    _setStatus('scanning for the audio service UUID');
    _say('scan filter: ${OmiGatt.audioService}');

    final found = Completer<BluetoothDevice>();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _say('saw ${r.device.remoteId} rssi=${r.rssi} '
            'name="${r.advertisementData.advName}" '
            'connectable=${r.advertisementData.connectable}');
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
      _setStatus('no device advertising the audio service');
      _say('nothing found. device powered off, out of range, or silent.');
      // Keep looking. The pendant may simply be off, and it should be picked up
      // whenever it comes back without anyone having to touch the app.
      if (!_stopping) {
        await Future.delayed(const Duration(seconds: 5));
        if (!_stopping) await _scan();
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _setStatus('connecting to ${device.remoteId}');

    // The bond guard. A bond record is the one confirmed cause of the stuck
    // states: it hands Android a background auto-connect job and a cached
    // service map for a device that never asked to be bonded. We refuse to
    // proceed rather than paper over it.
    final bond = await device.bondState.first;
    _say('bond state: $bond');
    if (bond == BluetoothBondState.bonded) {
      _setStatus('DEVICE IS BONDED — forget it in Android Bluetooth settings');
      _say('refusing to continue. a bond will break reconnect after range loss.');
      return;
    }

    _linkUp = false;
    _connSub = device.connectionState.listen((s) {
      _say('connection state: $s');
      if (s == BluetoothConnectionState.connected) {
        _linkUp = true;
        return;
      }
      if (!_linkUp) return; // the replayed pre-connection state, not a drop
      _linkUp = false;
      _say('disconnect reason: ${device.disconnectReason}');
      _setStatus('disconnected');

      // A silent disappearance is not necessarily a fault. A three-second
      // button hold powers the pendant off and sends nothing at all, so
      // "gone" and "broken" look identical from here. We rescan either way;
      // if it powered off, the scan simply finds nothing until it is back.
      if (!_stopping) _scheduleReconnect();
    });

    // mtu: null suppresses flutter_blue_plus's automatic 512-byte request.
    // The CV1 initiates the exchange itself and needs >= 100 bytes before it
    // will send audio; getting in the way of that drops the stream silently.
    // License.nonprofit is personal use. flutter_blue_plus 2.x is NOT MIT —
    // commercial use requires a paid license. If 80hd ever ships as a product
    // this becomes either a purchase or a swap to universal_ble.
    await device.connect(
      license: License.nonprofit,
      autoConnect: false,
      mtu: null,
    );
    _say('connected');

    // Started as soon as the link is up, before any of the slow discovery work,
    // so there is no window where a backgrounded app can be frozen mid-setup.
    await CaptureService.start();

    // The device drives the packet-size exchange itself, and it happens after
    // the connection completes — reading device.mtu straight away just returns
    // the 23-byte BLE default. Watch it instead of sampling it once.
    _charSubs.add(device.mtu.listen((m) {
      _mtu = m;
      _say('MTU now $m');
      if (mounted) setState(() {});
    }));
    await Future.delayed(const Duration(seconds: 3));
    _say('MTU after negotiation window: $_mtu');

    // The handoff notes said the device initiates the exchange itself and that
    // we should stay out of the way. On firmware 3.0.19 it does not: the link
    // sits at the 23-byte BLE default, which leaves 20 bytes of payload and no
    // audio at all. So we ask.
    if (_mtu < 100) {
      _say('device did not negotiate. requesting MTU ourselves.');
      try {
        final got = await device.requestMtu(512);
        _mtu = got;
        _say('requestMtu returned $got');
      } catch (e) {
        _say('requestMtu failed: $e');
      }
    }
    if (_mtu < 100) {
      _say('WARNING: MTU still below 100. the device will not send audio.');
    }

    await _dumpGatt(device);
    await _syncClock(device);
    await _subscribe(device);

    // Cancel first: a reconnect runs this path again, and two live timers would
    // interleave and double every reported figure.
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Close out a burst here rather than waiting for the next one to start,
      // so a burst that is never followed by another still gets reported.
      final last = _lastPacketAt;
      if (last != null && _burstStartedAt != null) {
        final idle = DateTime.now().difference(last);
        if (idle > _burstGap) {
          _say('BURST #$_bursts ended: '
              '${last.difference(_burstStartedAt!).inMilliseconds}ms of audio, '
              'silent for ${idle.inSeconds}s');
          _burstStartedAt = null;
        }
      }
      _say('stats: packets=$_packets bytes=$_audioBytes gaps=$_gaps '
          'bursts=$_bursts reconnects=$_reconnects lastIndex=$_lastIndex '
          'mtu=$_mtu');
    });
  }

  /// Walk every service and characteristic, reading anything readable. This is
  /// the part that replaces sending screenshots back and forth.
  Future<void> _dumpGatt(BluetoothDevice device) async {
    _setStatus('discovering services');
    final services = await device.discoverServices();
    _say('=== GATT TABLE: ${services.length} services ===');

    for (final s in services) {
      _say('service ${s.uuid}  (${OmiGatt.label(s.uuid)})');
      for (final c in s.characteristics) {
        final props = <String>[
          if (c.properties.read) 'READ',
          if (c.properties.write) 'WRITE',
          if (c.properties.writeWithoutResponse) 'WRITE_NR',
          if (c.properties.notify) 'NOTIFY',
          if (c.properties.indicate) 'INDICATE',
        ].join(',');
        var line = '  char ${c.uuid}  (${OmiGatt.label(c.uuid)})  [$props]';

        if (c.properties.read) {
          try {
            // Timeout: a characteristic that never answers must not stall the
            // whole dump.
            final v = await c.read().timeout(const Duration(seconds: 5));
            final ascii = v.every((b) => b >= 0x20 && b < 0x7f)
                ? ' "${String.fromCharCodes(v)}"'
                : '';
            // One line, not two: logcat is filtered on the OMI prefix and a
            // continuation line would be dropped from the capture.
            line += '  value: ${hex(v)}$ascii';
          } catch (e) {
            line += '  read failed: $e';
          }
        }
        _say(line);
      }
    }
    _say('=== END GATT TABLE ===');
  }

  /// The device clock is pure software with no battery backing. It drifts and
  /// it resets. Firmware also refuses to write offline audio unless the clock
  /// reads past 1700000000, so this is not optional even when it looks like it.
  Future<void> _syncClock(BluetoothDevice device) async {
    final c = _find(device, OmiGatt.timeService, OmiGatt.timeWrite);
    if (c == null) {
      _say('no time sync characteristic — skipping clock sync');
      return;
    }
    final epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bytes = Uint8List(4)..buffer.asByteData().setUint32(0, epoch, Endian.little);
    await c.write(bytes, withoutResponse: false);
    _say('clock synced to $epoch (${hex(bytes)})');
  }

  Future<void> _subscribe(BluetoothDevice device) async {
    final button = _find(device, OmiGatt.buttonService, OmiGatt.buttonEvents);
    if (button != null) {
      _charSubs.add(button.onValueReceived.listen((v) {
        if (v.isEmpty) return;
        _lastButton = v.first;
        _say('BUTTON ${hex(v)} -> ${ButtonEvent.describe(v.first)}');
        if (mounted) setState(() {});
      }));
      await button.setNotifyValue(true);
      _say('subscribed to button events');
    } else {
      _say('button characteristic not found');
    }

    final audio = _find(device, OmiGatt.audioService, OmiGatt.audioData);
    if (audio != null) {
      _charSubs.add(audio.onValueReceived.listen(_onAudio));
      await audio.setNotifyValue(true);
      _say('subscribed to audio');
      _setStatus('streaming');
    } else {
      _say('audio characteristic not found');
      _setStatus('no audio characteristic');
    }
  }

  void _onAudio(List<int> raw) {
    final p = AudioPacket.parse(raw);
    if (p == null) return;

    final now = DateTime.now();
    final since = _lastPacketAt == null ? null : now.difference(_lastPacketAt!);
    if (since == null || since > _burstGap) {
      if (_burstStartedAt != null && since != null) {
        final len = _lastPacketAt!.difference(_burstStartedAt!);
        _say('BURST end: ${len.inMilliseconds}ms of speech, '
            'then ${since.inMilliseconds}ms of silence');
      }
      _bursts++;
      _burstStartedAt = now;
      _say('BURST start #$_bursts'
          '${since == null ? "" : " after ${since.inMilliseconds}ms silence"}');
    }
    _lastPacketAt = now;

    _packets++;
    _audioBytes += p.opus.length;

    // uint16 wraps at 65536; a wrap is not a gap.
    if (_lastIndex >= 0) {
      final expected = (_lastIndex + 1) & 0xFFFF;
      if (p.index != expected) {
        _gaps++;
        _say('GAP: expected $expected got ${p.index} (gap #$_gaps)');
      }
    }
    _lastIndex = p.index;

    if (_packets <= 3 || _packets % 500 == 0) {
      _say('audio #$_packets index=${p.index} offset=${p.frameOffset} '
          'len=${p.opus.length}');
    }
  }

  /// Rescan and reconnect after a dropped link.
  ///
  /// Deliberately a fresh scan rather than autoConnect. autoConnect leans on
  /// Android's own background scan scheduling, which is slow and — more to the
  /// point — is the same machinery a bond record hooks into. We keep the
  /// reconnect in our own hands where we can see it.
  Future<void> _scheduleReconnect() async {
    if (_reconnecting || _stopping) return;
    _reconnecting = true;
    _reconnects++;

    // Cancel the old characteristic subscriptions before scanning; they belong
    // to a GATT client that no longer exists.
    _statsTimer?.cancel();
    for (final s in _charSubs) {
      await s.cancel();
    }
    _charSubs.clear();
    await _connSub?.cancel();

    _say('reconnect #$_reconnects: waiting 2s, then rescanning');
    await Future.delayed(const Duration(seconds: 2));
    _reconnecting = false;
    if (_stopping) return;
    await _scan();
  }

  BluetoothCharacteristic? _find(
      BluetoothDevice device, Guid service, Guid characteristic) {
    for (final s in device.servicesList) {
      if (s.uuid != service) continue;
      for (final c in s.characteristics) {
        if (c.uuid == characteristic) return c;
      }
    }
    return null;
  }

  /// Always wait for the disconnect callback before closing. Closing early
  /// leaks a GATT client; Android caps the system near thirty, and exhaustion
  /// is what "error 133 for no reason" usually turns out to be.
  Future<void> _teardown() async {
    _stopping = true;
    _statsTimer?.cancel();
    await _scanSub?.cancel();
    for (final s in _charSubs) {
      await s.cancel();
    }
    _charSubs.clear();
    final d = _device;
    if (d != null && d.isConnected) {
      await d.disconnect();
    }
    await _connSub?.cancel();
    await CaptureService.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('omi capture probe')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_status, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('packets $_packets   bytes $_audioBytes   '
                    'gaps $_gaps   mtu $_mtu'),
                Text(_lastButton >= 0
                    ? 'last button: ${ButtonEvent.describe(_lastButton)}'
                    : 'last button: none'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (_, i) => Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Text(_lines[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await _teardown();
          setState(() {
            _lines.clear();
            _packets = 0;
            _audioBytes = 0;
            _gaps = 0;
            _bursts = 0;
            _reconnects = 0;
            _lastIndex = -1;
            _lastPacketAt = null;
            _burstStartedAt = null;
          });
          _stopping = false;
          await _start();
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
