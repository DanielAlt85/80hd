/// GATT constants for the Omi CV1.
///
/// Verified against a real device (firmware 3.0.19, MAC E4:BC:27:B6:8B:2B) on
/// 2026-08-31 with nRF Connect. Anything marked "undocumented" was present on
/// the device but absent from BasedHardware's own UUID table.
library;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

Guid _g(String s) => Guid(s);

class OmiGatt {
  /// Audio service. Also the scan filter — this is how we find the device
  /// without touching its name or MAC.
  static final audioService = _g('19b10000-e8f2-537e-4f6c-d104768a1214');
  static final audioData = _g('19b10001-e8f2-537e-4f6c-d104768a1214');

  /// Reads 0x15 (21) on the CV1 => Opus, 16 kHz, mono, 20 ms frames.
  static final codecId = _g('19b10002-e8f2-537e-4f6c-d104768a1214');

  static final settingsService = _g('19b10010-e8f2-537e-4f6c-d104768a1214');
  static final dimRatio = _g('19b10011-e8f2-537e-4f6c-d104768a1214');
  static final micGain = _g('19b10012-e8f2-537e-4f6c-d104768a1214');
  static final charging = _g('19b10013-e8f2-537e-4f6c-d104768a1214');

  static final featuresService = _g('19b10020-e8f2-537e-4f6c-d104768a1214');
  static final featureFlags = _g('19b10021-e8f2-537e-4f6c-d104768a1214');

  /// Time sync. The device clock is pure software with no battery backing, so
  /// it drifts and resets. Write on every connect.
  static final timeService = _g('19b10030-e8f2-537e-4f6c-d104768a1214');
  static final timeWrite = _g('19b10031-e8f2-537e-4f6c-d104768a1214');
  static final timeRead = _g('19b10032-e8f2-537e-4f6c-d104768a1214');

  static final buttonService = _g('23ba7924-0000-1000-7450-346eac492e92');
  static final buttonEvents = _g('23ba7925-0000-1000-7450-346eac492e92');

  /// Ring buffer / onboard storage. Firmware >= 3.0.20 only; absent on 3.0.19.
  static final storageService = _g('30295780-4301-eabd-2904-2849adfeae43');
  static final storageCommand = _g('30295781-4301-eabd-2904-2849adfeae43');
  static final storageStatus = _g('30295782-4301-eabd-2904-2849adfeae43');

  static final batteryService = _g('0000180f-0000-1000-8000-00805f9b34fb');
  static final batteryLevel = _g('00002a19-0000-1000-8000-00805f9b34fb');

  static final deviceInfoService = _g('0000180a-0000-1000-8000-00805f9b34fb');
  static final firmwareRevision = _g('00002a26-0000-1000-8000-00805f9b34fb');
  static final hardwareRevision = _g('00002a27-0000-1000-8000-00805f9b34fb');
  static final modelNumber = _g('00002a24-0000-1000-8000-00805f9b34fb');
  static final manufacturerName = _g('00002a29-0000-1000-8000-00805f9b34fb');

  /// Undocumented: Zephyr MCUmgr SMP service. This is the over-the-air firmware
  /// update path. Open, unauthenticated as far as we have looked.
  static final smpService = _g('8d53dc1d-1db7-4cd3-868b-8a527460aa84');

  /// Undocumented and unidentified. Present on the device; purpose unknown.
  static final unknownService = _g('cab1ab95-2ea5-4f4d-bb56-874b72cfc984');

  /// Human-readable name for a UUID, for log dumps.
  static String label(Guid g) {
    final s = g.str.toLowerCase();
    return _names[s] ?? 'unknown';
  }

  static final Map<String, String> _names = {
    audioService.str.toLowerCase(): 'audio service',
    audioData.str.toLowerCase(): 'audio data',
    codecId.str.toLowerCase(): 'codec id',
    settingsService.str.toLowerCase(): 'settings service',
    dimRatio.str.toLowerCase(): 'dim ratio',
    micGain.str.toLowerCase(): 'mic gain',
    charging.str.toLowerCase(): 'charging',
    featuresService.str.toLowerCase(): 'features service',
    featureFlags.str.toLowerCase(): 'feature flags',
    timeService.str.toLowerCase(): 'time sync service',
    timeWrite.str.toLowerCase(): 'time write',
    timeRead.str.toLowerCase(): 'time read',
    buttonService.str.toLowerCase(): 'button service',
    buttonEvents.str.toLowerCase(): 'button events',
    storageService.str.toLowerCase(): 'storage service',
    storageCommand.str.toLowerCase(): 'storage command',
    storageStatus.str.toLowerCase(): 'storage status',
    batteryService.str.toLowerCase(): 'battery service',
    batteryLevel.str.toLowerCase(): 'battery level',
    deviceInfoService.str.toLowerCase(): 'device information',
    firmwareRevision.str.toLowerCase(): 'firmware revision',
    hardwareRevision.str.toLowerCase(): 'hardware revision',
    modelNumber.str.toLowerCase(): 'model number',
    manufacturerName.str.toLowerCase(): 'manufacturer name',
    smpService.str.toLowerCase(): 'SMP / MCUmgr firmware update',
    unknownService.str.toLowerCase(): 'undocumented service',
  };
}

/// Button event codes. 3 and 4 exist in firmware but are never sent.
/// A 3-second hold powers the device off and sends nothing at all — a silent
/// disappearance must be read as "powered off", not as a connection failure.
class ButtonEvent {
  static const singleTap = 1;
  static const doubleTap = 2;
  static const longHoldRelease = 5;

  static String describe(int code) => switch (code) {
        1 => 'single tap',
        2 => 'double tap',
        5 => 'release after long hold',
        _ => 'unrecognised ($code)',
      };
}

/// One audio notification off the wire.
///
/// Layout: [packet_index: uint16 LE][frame_offset: uint8][opus bytes...]
/// frame_offset == 0 starts a new Opus frame; accumulate across notifications
/// with incrementing offset until the next 0.
class AudioPacket {
  final int index;
  final int frameOffset;
  final List<int> opus;

  AudioPacket(this.index, this.frameOffset, this.opus);

  static AudioPacket? parse(List<int> raw) {
    if (raw.length < 3) return null;
    final index = raw[0] | (raw[1] << 8);
    return AudioPacket(index, raw[2], raw.sublist(3));
  }
}
