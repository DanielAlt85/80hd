/// Writes captured audio to disk on the phone, one file per burst.
///
/// The Opus frames are stored exactly as they came off the radio. The phone
/// never decodes them: the pendant already did the voice detection, so there is
/// nothing for a phone-side decoder to decide, and keeping Opus out of the
/// mobile build means we do not need the forked opus_dart/opus_flutter packages
/// at all. Decoding happens on the host, next to the transcription, in ordinary
/// Python.
///
/// Format — little endian throughout:
///
///   header, 32 bytes
///     0   magic        "OMICAP01"        8 bytes
///     8   startEpochMs uint64            when the first frame arrived
///     16  codecId      uint8             21 = Opus 16 kHz mono 20 ms
///     17  sampleRate   uint32            16000
///     21  reserved     11 bytes of zero
///
///   then one record per frame
///     0   offsetMs     uint32            since startEpochMs, arrival time
///     4   packetIndex  uint16            the device's own counter
///     6   frameLen     uint16
///     8   opus         frameLen bytes
///
/// Arrival time is recorded because the protocol cannot express silence: the
/// device's packet counter does not advance while nobody is speaking, so a one
/// second pause and a twenty minute one are indistinguishable from the bytes
/// alone. The counter is still worth keeping — a jump in it means speech the
/// device captured and we failed to receive, which is a different problem and
/// needs to reach the transcript differently.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class SegmentWriter {
  static const _magic = 'OMICAP01';
  static const _headerLen = 32;

  /// Frames buffered before hitting the disk. At 50 frames a second this is a
  /// flush roughly every second — often enough that a crash costs almost
  /// nothing, rare enough that we are not doing 50 syscalls a second.
  static const _flushEvery = 50;

  final int codecId;
  final int sampleRate;

  Directory? _dir;
  IOSink? _sink;
  File? _file;
  int _startEpochMs = 0;
  int _framesSinceFlush = 0;

  int frames = 0;
  int bytes = 0;

  SegmentWriter({this.codecId = 21, this.sampleRate = 16000});

  bool get isOpen => _sink != null;
  String? get path => _file?.path;

  static const _channel = MethodChannel('omi_capture/service');

  /// App-private storage, not shared storage. Nothing else on the phone can
  /// read these, and they go away with the app.
  Future<Directory> _segmentsDir() async {
    if (_dir != null) return _dir!;
    final base = await _channel.invokeMethod<String>('filesDir');
    final dir = Directory('$base/segments');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<File> open(DateTime startedAt) async {
    await close();
    final dir = await _segmentsDir();
    _startEpochMs = startedAt.millisecondsSinceEpoch;
    final f = File('${dir.path}/seg-$_startEpochMs.omi');
    final sink = f.openWrite();

    final header = Uint8List(_headerLen);
    final view = ByteData.sublistView(header);
    header.setRange(0, 8, _magic.codeUnits);
    view.setUint64(8, _startEpochMs, Endian.little);
    view.setUint8(16, codecId);
    view.setUint32(17, sampleRate, Endian.little);
    sink.add(header);

    _file = f;
    _sink = sink;
    frames = 0;
    bytes = 0;
    _framesSinceFlush = 0;
    return f;
  }

  void write(DateTime arrivedAt, int packetIndex, List<int> opus) {
    final sink = _sink;
    if (sink == null) return;

    final record = Uint8List(8 + opus.length);
    final view = ByteData.sublistView(record);
    final offset = arrivedAt.millisecondsSinceEpoch - _startEpochMs;
    // uint32 milliseconds caps a single segment at ~49 days. A burst is seconds
    // long, so clamping at zero for a clock that stepped backwards is the only
    // case worth guarding.
    view.setUint32(0, offset < 0 ? 0 : offset, Endian.little);
    view.setUint16(4, packetIndex, Endian.little);
    view.setUint16(6, opus.length, Endian.little);
    record.setRange(8, record.length, opus);
    sink.add(record);

    frames++;
    bytes += opus.length;
    if (++_framesSinceFlush >= _flushEvery) {
      _framesSinceFlush = 0;
      sink.flush();
    }
  }

  Future<void> close() async {
    final sink = _sink;
    if (sink == null) return;
    _sink = null;
    await sink.flush();
    await sink.close();
  }

  /// Everything written so far, newest first. The uploader will want this.
  Future<List<FileSystemEntity>> listSegments() async {
    final dir = await _segmentsDir();
    final files = (await dir.list().toList())
        .where((e) => e.path.endsWith('.omi'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<int> totalBytesOnDisk() async {
    var total = 0;
    for (final f in await listSegments()) {
      if (f is File) total += await f.length();
    }
    return total;
  }
}
