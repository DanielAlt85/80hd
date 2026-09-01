/// Moves finished segments off the phone.
///
/// Store and forward: the pendant to phone link is the only one that has to be
/// reliable in real time, because the phone is the only thing in Bluetooth
/// range. Everything after it can be as intermittent as the network actually
/// is, and the phone simply holds a backlog until the host is reachable.
///
/// A segment is deleted from the phone only when the host returns a SHA-256
/// matching the bytes we hold. Not when the upload returns 200, not when the
/// socket closes cleanly — when the far end proves it has the same file.
/// Nothing frees its own copy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'segment_writer.dart';

class UploadResult {
  final int uploaded;
  final int deleted;
  final int failed;
  final int skipped;

  const UploadResult({
    this.uploaded = 0,
    this.deleted = 0,
    this.failed = 0,
    this.skipped = 0,
  });

  bool get idle => uploaded == 0 && failed == 0 && skipped == 0;

  @override
  String toString() =>
      'uploaded $uploaded, deleted $deleted, failed $failed, skipped $skipped';
}

class Uploader {
  /// The host, as a full base URL. Only a default — the real value is a
  /// setting, because which mesh carries this turned out to be the least
  /// stable decision in the project.
  ///
  /// This is a NordVPN Meshnet address. Tailscale was the original choice and
  /// is the better tool, but NordVPN on the host captures the default route and
  /// no split-tunnel configuration would release tailscaled, so Tailscale's own
  /// traffic egressed through a Nord exit server and no peer could reach this
  /// machine. Using Nord's own mesh removes the fight rather than winning it.
  ///
  /// Worth knowing if this ever stops working: Nord announced Meshnet's
  /// shutdown for December 2025 and reversed after public backlash. It is
  /// supported but was close to deleted, so treat it as replaceable — which is
  /// why this is a setting and not a constant.
  ///
  /// Override for testing over the USB cable:
  ///   adb reverse tcp:8723 tcp:8723
  ///   flutter build apk --debug --dart-define=OMI_URL=http://127.0.0.1:8723
  static const defaultBase = String.fromEnvironment(
    'OMI_URL',
    defaultValue: 'http://100.70.96.212:8723',
  );

  final String base;
  final SegmentWriter writer;
  final void Function(String) log;

  Uploader({
    required this.writer,
    required this.log,
    this.base = defaultBase,
  });

  bool _running = false;

  /// Why the last reachability check failed, in words a person can act on.
  /// "Unreachable" covers several very different problems and points at none
  /// of them; a name that will not resolve needs a different fix from a
  /// machine that is switched off.
  String? lastError;

  Future<bool> reachable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse('$base/health'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      if (res.statusCode == 200) {
        lastError = null;
        return true;
      }
      lastError = 'Server answered ${res.statusCode}';
      return false;
    } on SocketException catch (e) {
      final host = Uri.tryParse(base)?.host ?? base;
      lastError = e.osError?.errorCode == 7 ||
              e.message.contains('Failed host lookup')
          // Specifically the MagicDNS case, which is a toggle rather than a
          // network fault, and is invisible unless we name it.
          ? 'Cannot look up $host. If this is a Tailscale name, turn on '
              '"Use Tailscale DNS" in the Tailscale app.'
          : 'Cannot reach $host';
      return false;
    } on HandshakeException {
      lastError = 'The server\'s certificate was rejected';
      return false;
    } catch (e) {
      lastError = '$e';
      return false;
    } finally {
      client.close();
    }
  }

  /// Upload everything closed and on disk. Safe to call on a timer; overlapping
  /// calls return immediately rather than uploading the same file twice.
  Future<UploadResult> run() async {
    if (_running) return const UploadResult();
    _running = true;
    try {
      return await _run();
    } finally {
      _running = false;
    }
  }

  Future<UploadResult> _run() async {
    final segments = await writer.listSegments();
    if (segments.isEmpty) return const UploadResult();

    // Never touch the file currently being written to. It has no trailing
    // frames yet and its hash would be wrong the moment the next packet lands.
    final openPath = writer.isOpen ? writer.path : null;

    var uploaded = 0, deleted = 0, failed = 0, skipped = 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

    try {
      for (final entity in segments) {
        if (entity is! File) continue;
        if (entity.path == openPath) {
          skipped++;
          continue;
        }

        final name = entity.path.split('/').last;
        final bytes = await entity.readAsBytes();
        final local = sha256.convert(bytes).toString();

        try {
          final req = await client.postUrl(Uri.parse('$base/upload/$name'));
          req.headers.contentType = ContentType.binary;
          req.contentLength = bytes.length;
          req.add(bytes);

          final res = await req.close().timeout(const Duration(seconds: 60));
          final body = await res.transform(utf8.decoder).join();

          if (res.statusCode != 200) {
            log('upload $name failed: HTTP ${res.statusCode} $body');
            failed++;
            continue;
          }

          final remote = (jsonDecode(body) as Map<String, dynamic>)['sha256'];
          if (remote != local) {
            // Do not delete. Do not retry blindly either — a mismatch means
            // something corrupted the bytes in flight, and uploading again
            // without knowing what would just do it twice.
            log('upload $name HASH MISMATCH: local $local remote $remote');
            failed++;
            continue;
          }

          uploaded++;
          await entity.delete();
          deleted++;
          log('uploaded and freed $name (${bytes.length} bytes)');
        } catch (e) {
          // Unreachable host, dropped wifi, host restarting. The file stays put
          // and the next pass tries again. This is the normal case, not an
          // error, so it is logged quietly.
          log('upload $name deferred: $e');
          failed++;
        }
      }
    } finally {
      client.close();
    }

    return UploadResult(
      uploaded: uploaded,
      deleted: deleted,
      failed: failed,
      skipped: skipped,
    );
  }
}
