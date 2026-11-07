/// Pre-flight checks for GGUF model files, run BEFORE any native call.
///
/// Why this exists: Clawzilla kicked the user out of the app (process
/// death, below Dart) when loading a model on every backend. Dart try/catch
/// cannot catch a native crash, so the only Dart-side defence is to refuse
/// bad files before native code ever touches them, and to refuse loads
/// that cannot fit in RAM instead of letting the OS kill the app.
///
/// Both checks return null when the file passes, or a plain-words error
/// message that the caller reports through the normal error path. They
/// never throw for a bad file: every failure mode is a return value.
///
/// [inspect] reads the same header-only section and returns a one-line
/// summary (name, architecture, quant, size) for model lists. It is NOT a
/// safety verdict — a file that passes the header check can still be a bad
/// model; the bring-along scan is what vets where a model came from.
library;

import 'dart:io';
import 'dart:typed_data';

/// What a model file's header says it is: the name the maker gave it, the
/// architecture family, the dominant quantisation, and its size on disk.
class ModelInfo {
  const ModelInfo({
    required this.name,
    required this.architecture,
    required this.quant,
    required this.sizeLabel,
  });

  /// Display name from `general.name`, or a cleaned-up file name when the
  /// header has no name.
  final String name;

  /// Architecture family from `general.architecture` (e.g. `llama`).
  /// Empty when the header does not say.
  final String architecture;

  /// Dominant tensor quantisation (e.g. `Q4_K_M`), or empty when unknown.
  final String quant;

  /// Size on disk, e.g. `2.0 GB`.
  final String sizeLabel;

  /// One line for a model list: `Llama 3.2 3B Instruct · llama · Q4_K_M · 2.0 GB`.
  /// Empty fields are dropped, never shown as blanks.
  String get summaryLine {
    final parts = <String>[name];
    if (architecture.isNotEmpty) parts.add(architecture);
    if (quant.isNotEmpty) parts.add(quant);
    parts.add(sizeLabel);
    return parts.join(' · ');
  }
}

class ModelPreflight {
  /// Overhead added to the file size when estimating RAM need: context
  /// buffers and runtime state. A coarse estimate, not a guarantee — see
  /// [checkFits].
  static const int _overheadBytes = 512 * 1024 * 1024;

  /// How much of the file head [inspect] reads. The metadata block and the
  /// tensor list always live at the start of the file, before any weights,
  /// and are well under this for every model that fits on a phone.
  static const int _inspectBytes = 8 * 1024 * 1024;

  /// Verify [path] is a readable GGUF file with a parseable header.
  static Future<String?> verify(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) {
        return 'That model file is gone — pick it again.';
      }
      final length = await file.length();
      if (length <= 0) {
        return 'That model file is empty.';
      }
      if (length < 24) {
        return 'That file is too small to be a model.';
      }
      final raf = await file.open();
      try {
        final header = await raf.read(24);
        if (header.length < 24) {
          return 'That file is too small to be a model.';
        }
        if (header[0] != 0x47 ||
            header[1] != 0x47 ||
            header[2] != 0x55 ||
            header[3] != 0x46) {
          return 'That file is not a model file.';
        }
        final data = ByteData.sublistView(Uint8List.fromList(header));
        final version = data.getUint32(4, Endian.little);
        if (version != 2 && version != 3) {
          return 'That model file is too new or too old for this app.';
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
    } catch (_) {
      return 'Could not read that file.';
    }
  }

  /// Read a model file's header and return what it says it is, or null
  /// when the file fails the basic header check or the header cannot be
  /// parsed. Never throws. A null here means "show the [verify] error
  /// instead of a summary line", not "the file is safe".
  static Future<ModelInfo?> inspect(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length < 24) return null;
      final raf = await file.open();
      try {
        final bytes = await raf.read(
          length < _inspectBytes ? length : _inspectBytes,
        );
        return _parseHeader(bytes, length);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Parse the GGUF header out of [bytes] (the file head, at least 24
  /// bytes). [fileSize] is the whole file's size, for the size label.
  /// Returns null on any parse failure — the caller falls back to the
  /// [verify] error string.
  static ModelInfo? _parseHeader(Uint8List bytes, int fileSize) {
    try {
      final data = ByteData.sublistView(bytes);
      if (bytes.length < 24) return null;
      if (data.getUint32(0, Endian.little) != 0x46554747) return null;
      final version = data.getUint32(4, Endian.little);
      if (version != 2 && version != 3) return null;

      int offset;
      int tensorCount;
      int metadataCount;
      if (version == 3) {
        tensorCount = data.getUint64(8, Endian.little);
        metadataCount = data.getUint64(16, Endian.little);
        offset = 24;
      } else {
        tensorCount = data.getUint32(8, Endian.little);
        metadataCount = data.getUint32(12, Endian.little);
        offset = 24;
      }

      // --- metadata key/value pairs -------------------------------------
      final meta = <String, Object?>{};
      for (var i = 0; i < metadataCount; i++) {
        final key = _readString(bytes, data, offset);
        if (key == null) return _infoFromMeta(meta, null, fileSize);
        offset = key.$2;
        if (offset + 4 > bytes.length) {
          return _infoFromMeta(meta, null, fileSize);
        }
        final valueType = data.getUint32(offset, Endian.little);
        offset += 4;
        final value = _readValue(bytes, data, offset, valueType);
        if (value == null) return _infoFromMeta(meta, null, fileSize);
        offset = value.$2;
        meta[key.$1] = value.$1;
      }

      // --- tensor infos: dominant quant by total element count -----------
      final quantCounts = <int, int>{};
      for (var i = 0; i < tensorCount; i++) {
        final name = _readString(bytes, data, offset);
        if (name == null) break;
        offset = name.$2;
        if (offset + 4 > bytes.length) break;
        final nDims = data.getUint32(offset, Endian.little);
        offset += 4;
        if (nDims > 8 || offset + 8 * nDims + 12 > bytes.length) break;
        var elements = 1;
        for (var d = 0; d < nDims; d++) {
          elements *= data.getUint64(offset + 8 * d, Endian.little);
        }
        offset += 8 * nDims;
        final type = data.getUint32(offset, Endian.little);
        offset += 4;
        // Tensor data offset (uint64) — the last field of the info.
        offset += 8;
        quantCounts[type] = (quantCounts[type] ?? 0) + elements;
      }
      var dominantType = -1;
      var dominantElements = 0;
      quantCounts.forEach((type, elements) {
        if (elements > dominantElements) {
          dominantElements = elements;
          dominantType = type;
        }
      });
      return _infoFromMeta(
        meta,
        dominantType >= 0 ? _quantName(dominantType) : null,
        fileSize,
      );
    } catch (_) {
      return null;
    }
  }

  /// Build the [ModelInfo] from the parsed metadata map and the dominant
  /// quant name (either may be missing — fall back to the file name).
  /// `general.file_type` names the exact variant (Q4_K_M, Q3_K_L …) when
  /// the maker set it, so it wins over the dominant tensor type, which
  /// only ever says Q4_K.
  static ModelInfo _infoFromMeta(
    Map<String, Object?> meta,
    String? quant,
    int fileSize,
  ) {
    final name = meta['general.name'] as String?;
    final architecture = meta['general.architecture'] as String?;
    final sizeLabel = meta['general.size_label'] as String?;
    final fileType = meta['general.file_type'];
    final fileTypeQuant = fileType is int ? _fileTypeName(fileType) : null;
    final displayName = (name != null && name.isNotEmpty)
        ? name
        : (sizeLabel != null && sizeLabel.isNotEmpty ? sizeLabel : 'Model');
    return ModelInfo(
      name: displayName,
      architecture: architecture ?? '',
      quant: fileTypeQuant ?? quant ?? '',
      sizeLabel: _sizeLabel(fileSize),
    );
  }

  /// `general.file_type` numbers to the variant names in file names
  /// (Q4_K_M, Q3_K_L …). Null when the number is not a known variant.
  static String? _fileTypeName(int fileType) {
    return switch (fileType) {
      0 => 'F32',
      1 => 'F16',
      2 => 'Q4_0',
      3 => 'Q4_1',
      7 => 'Q8_0',
      8 => 'Q5_0',
      9 => 'Q5_1',
      10 => 'Q2_K',
      11 => 'Q3_K_S',
      12 => 'Q3_K_M',
      13 => 'Q3_K_L',
      14 => 'Q4_K_S',
      15 => 'Q4_K_M',
      16 => 'Q5_K_S',
      17 => 'Q5_K_M',
      18 => 'Q6_K',
      19 => 'Q8_K',
      20 => 'IQ2_XXS',
      21 => 'IQ2_XS',
      22 => 'IQ3_XXS',
      23 => 'IQ1_S',
      24 => 'IQ4_NL',
      25 => 'IQ3_S',
      26 => 'IQ2_S',
      27 => 'IQ4_XS',
      28 => 'IQ1_M',
      29 => 'BF16',
      _ => null,
    };
  }

  /// A GGUF string: uint64 length + UTF-8 bytes. Returns (value, next
  /// offset) or null when the bytes run out.
  static (String, int)? _readString(
    Uint8List bytes,
    ByteData data,
    int offset,
  ) {
    final limit = bytes.length;
    if (offset + 8 > limit) return null;
    final length = data.getUint64(offset, Endian.little);
    offset += 8;
    if (length > 1 << 20 || offset + length > limit) return null;
    // [data] is a view over [bytes]; index into the byte list directly.
    final value = String.fromCharCodes(
      bytes.sublist(offset, offset + length),
    );
    return (value, offset + length);
  }

  /// Read one metadata value of GGUF type [type] at [offset].
  /// Returns (value, next offset) or null when the bytes run out.
  /// Arrays are skipped whole and stored as null — the header keys we
  /// care about (`general.name`, `general.architecture`) are plain
  /// strings, so an array value is simply not a name.
  static (Object?, int)? _readValue(
    Uint8List bytes,
    ByteData data,
    int offset,
    int type,
  ) {
    final limit = bytes.length;
    int scalarSize(int t) {
      switch (t) {
        case 0: // UINT8
        case 1: // INT8
          return 1;
        case 2: // UINT16
        case 3: // INT16
          return 2;
        case 4: // UINT32
        case 5: // INT32
        case 6: // FLOAT32
          return 4;
        case 7: // BOOL
          return 1;
        case 10: // UINT64
        case 11: // INT64
        case 12: // FLOAT64
          return 8;
        default:
          return -1;
      }
    }

    if (type == 8) {
      // STRING
      final s = _readString(bytes, data, offset);
      if (s == null) return null;
      return (s.$1, s.$2);
    }
    if (type == 9) {
      // ARRAY: element type + count, then the elements. Skip them all.
      if (offset + 12 > limit) return null;
      final elemType = data.getUint32(offset, Endian.little);
      final count = data.getUint64(offset + 4, Endian.little);
      var off = offset + 12;
      if (elemType == 8) {
        for (var i = 0; i < count; i++) {
          final s = _readString(bytes, data, off);
          if (s == null) return null;
          off = s.$2;
        }
      } else {
        final size = scalarSize(elemType);
        if (size < 0) return null;
        off += size * count;
        if (off > limit) return null;
      }
      return (null, off);
    }
    final size = scalarSize(type);
    if (size < 0 || offset + size > limit) return null;
    final Object? value = switch (type) {
      0 => data.getUint8(offset),
      1 => data.getInt8(offset),
      2 => data.getUint16(offset, Endian.little),
      3 => data.getInt16(offset, Endian.little),
      4 => data.getUint32(offset, Endian.little),
      5 => data.getInt32(offset, Endian.little),
      6 => data.getFloat32(offset, Endian.little),
      7 => data.getUint8(offset) != 0,
      10 => data.getUint64(offset, Endian.little),
      11 => data.getInt64(offset, Endian.little),
      12 => data.getFloat64(offset, Endian.little),
      _ => null,
    };
    if (value == null) return null;
    return (value, offset + size);
  }

  /// GGUF tensor type numbers (ggml_type) to the quant names users see in
  /// file names. The enum keeps the removed types' slots: Q8_0 is 8, not
  /// 6, and Q4_K is 12 — a file whose biggest tensors are type 12 is a
  /// Q4_K file, which is what a Q4_K_M model mostly is.
  static String? _quantName(int type) {
    return switch (type) {
      0 => 'F32',
      1 => 'F16',
      2 => 'Q4_0',
      3 => 'Q4_1',
      6 => 'Q5_0',
      7 => 'Q5_1',
      8 => 'Q8_0',
      10 => 'Q2_K',
      11 => 'Q3_K',
      12 => 'Q4_K',
      13 => 'Q5_K',
      14 => 'Q6_K',
      15 => 'Q8_K',
      16 => 'IQ2_XXS',
      17 => 'IQ2_XS',
      18 => 'IQ3_XXS',
      19 => 'IQ1_S',
      20 => 'IQ4_NL',
      21 => 'IQ3_S',
      22 => 'IQ2_S',
      23 => 'IQ4_XS',
      24 => 'IQ1_M',
      25 => 'BF16',
      26 => 'Q4_0_4_4',
      27 => 'Q4_0_4_8',
      28 => 'Q4_0_8_8',
      _ => null,
    };
  }

  /// `2.0 GB` / `850 MB` for a byte count.
  static String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  /// A friendly name for a model file: the file name with the extension,
  /// the quant tag (`-Q4_K_M`, `-IQ4_XS` …) and separators stripped, so
  /// `Llama-3.2-3B-Instruct-Q4_K_M.gguf` reads `Llama 3.2 3B Instruct`.
  /// Used wherever a file has no catalog entry of its own (headers,
  /// status chips, load dialogs).
  static String friendlyName(String fileName) {
    var name = fileName;
    if (name.toLowerCase().endsWith('.gguf')) {
      name = name.substring(0, name.length - 5);
    }
    // Trailing quant tag: -Q4_K_M, -Q8_0, -IQ4_XS, -Q2_K, -f16, -bf16…
    name = name.replaceAll(
      RegExp(r'[-_](Q\d|IQ\d|F16|F32|BF16)[_A-Z0-9]*$', caseSensitive: false),
      '',
    );
    name = name.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return name.isEmpty ? fileName : name;
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
    } catch (_) {
      return 'Could not read that file.';
    }
  }
}
