/// Pre-flight checks for GGUF model files, run BEFORE any native call.
///
/// Why this exists: LocalMind kicked the user out of the app (process
/// death, below Dart) when loading a model on every backend. Dart try/catch
/// cannot catch a native crash, so the only Dart-side defence is to refuse
/// bad files before native code ever touches them, and to refuse loads
/// that cannot fit in RAM instead of letting the OS kill the app.
///
/// Both checks return null when the file passes, or a user-facing error
/// message that the caller reports through the normal error path. They
/// never throw for a bad file: every failure mode is a return value.
library;

import 'dart:io';
import 'dart:typed_data';

class ModelPreflight {
  /// Overhead added to the file size when estimating RAM need: context
  /// buffers and runtime state. A coarse estimate, not a guarantee — see
  /// [checkFits].
  static const int _overheadBytes = 512 * 1024 * 1024;

  /// Verify [path] is a readable GGUF file with a parseable header.
  static Future<String?> verify(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) {
        return 'Model file not found.';
      }
      final length = await file.length();
      if (length <= 0) {
        return 'Model file is empty.';
      }
      if (length < 24) {
        return 'Model file is too small to be a GGUF file.';
      }
      final raf = await file.open();
      try {
        final header = await raf.read(24);
        if (header.length < 24) {
          return 'Model file is too small to be a GGUF file.';
        }
        if (header[0] != 0x47 ||
            header[1] != 0x47 ||
            header[2] != 0x55 ||
            header[3] != 0x46) {
          return 'That file is not a GGUF model (missing GGUF header).';
        }
        final data = ByteData.sublistView(Uint8List.fromList(header));
        final version = data.getUint32(4, Endian.little);
        if (version != 2 && version != 3) {
          return 'Unsupported GGUF version ($version).';
        }
        // The header must at least parse: tensor + metadata counts
        // readable at the version's offsets.
        if (version == 3) {
          data.getUint64(8, Endian.little);
          data.getUint64(16, Endian.little);
        } else {
          data.getUint32(8, Endian.little);
          data.getUint32(12, Endian.little);
        }
      } finally {
        await raf.close();
      }
      return null;
    } catch (e) {
      return 'Could not read model file: $e';
    }
  }

  /// RAM gate: refuse loads that cannot fit. [totalRamMb] is total device
  /// RAM in MB; 0 or less means unknown, and the gate is skipped rather
  /// than blocking on unknown hardware. Coarse by design: it compares
  /// against total RAM, not free RAM, so it catches impossible loads,
  /// not every possible out-of-memory kill.
  static Future<String?> checkFits(String path, int totalRamMb) async {
    if (totalRamMb <= 0) return null;
    try {
      final size = await File(path).length();
      final needed = size + _overheadBytes;
      final total = totalRamMb * 1024 * 1024;
      if (needed > total) {
        final needGb = (needed / (1024 * 1024 * 1024)).toStringAsFixed(1);
        final haveGb = (totalRamMb / 1024).toStringAsFixed(1);
        return 'Model needs about $needGb GB but this device has $haveGb GB of RAM.';
      }
      return null;
    } catch (e) {
      return 'Could not read model file: $e';
    }
  }
}
