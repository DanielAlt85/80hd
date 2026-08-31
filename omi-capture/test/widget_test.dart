import 'package:flutter_test/flutter_test.dart';
import 'package:omi_capture/omi_gatt.dart';

void main() {
  group('AudioPacket.parse', () {
    test('reads the index as little endian', () {
      // Taken off a real device: DC-00-00 was packet 220, frame offset 0.
      final p = AudioPacket.parse([0xDC, 0x00, 0x00, 0xB8, 0x01])!;
      expect(p.index, 220);
      expect(p.frameOffset, 0);
      expect(p.opus, [0xB8, 0x01]);
    });

    test('reads an index above 255', () {
      // CC-01 is 460, not 204 and not 52225. Byte order is the whole point.
      final p = AudioPacket.parse([0xCC, 0x01, 0x00, 0xFF])!;
      expect(p.index, 460);
    });

    test('accepts a packet carrying no audio', () {
      // Three header bytes and nothing after is well formed, just empty.
      final p = AudioPacket.parse([0x01, 0x00, 0x00])!;
      expect(p.index, 1);
      expect(p.opus, isEmpty);
    });

    test('rejects anything too short to hold a header', () {
      expect(AudioPacket.parse([]), isNull);
      expect(AudioPacket.parse([0x01, 0x00]), isNull);
    });
  });

  group('ButtonEvent', () {
    test('names the codes the firmware actually sends', () {
      expect(ButtonEvent.describe(1), 'single tap');
      expect(ButtonEvent.describe(2), 'double tap');
      expect(ButtonEvent.describe(5), 'release after long hold');
    });

    test('does not pretend to recognise 3 and 4', () {
      // Defined in firmware, never sent. If one ever arrives we want to see it
      // called out rather than quietly mapped onto something plausible.
      expect(ButtonEvent.describe(3), contains('unrecognised'));
      expect(ButtonEvent.describe(4), contains('unrecognised'));
    });
  });

  group('OmiGatt', () {
    test('every UUID is well formed', () {
      // A mistyped UUID throws inside Guid, and it threw at runtime on the
      // device rather than here: the SMP service was transcribed with thirteen
      // hex digits in its last group instead of twelve.
      expect(OmiGatt.smpService.str.split('-').last.length, 12);
      expect(
        OmiGatt.label(OmiGatt.smpService),
        'SMP / MCUmgr firmware update',
      );
    });

    test('labels an unknown UUID rather than throwing', () {
      expect(OmiGatt.label(OmiGatt.audioData), 'audio data');
    });
  });
}
