import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _glbMagic = 0x46546C67; // 'glTF' read little-endian.
const int _jsonChunkType = 0x4E4F534A;
const int _binChunkType = 0x004E4942;

/// Moves every `data:` URI image in [glb] into the BIN chunk as a `bufferView`,
/// tagging it with the mime type sniffed from the payload's magic bytes.
///
/// Hunyuan3D-2.1 exports through pygltflib, which embeds textures as base64
/// `data:` URIs *and* declares `image/png` for payloads that are actually JPEG.
/// Android's Filament glTF loader rejects both, so an object that generated
/// fine failed to place. Repacking here covers any backend's export quirks.
///
/// A GLB with no `data:` images — every world `sky.glb`, and any object export
/// that is already spec-correct — comes back untouched. So does anything this
/// cannot parse: a mangled repack would be worse than no repack.
Uint8List repackGlbDataUriImages(Uint8List glb) {
  try {
    return _repack(glb) ?? glb;
  } catch (error) {
    stderr.writeln('[glb] repack skipped, keeping the original bytes: $error');
    return glb;
  }
}

/// Returns `null` when there is nothing to do, so the caller keeps [glb].
Uint8List? _repack(Uint8List glb) {
  if (glb.length < 12) {
    return null;
  }
  final source = ByteData.sublistView(glb);
  if (source.getUint32(0, Endian.little) != _glbMagic) {
    return null;
  }

  Uint8List? jsonChunk;
  Uint8List? binChunk;
  var offset = 12;
  while (offset + 8 <= glb.length) {
    final length = source.getUint32(offset, Endian.little);
    final type = source.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    final end = start + length;
    if (end > glb.length) {
      throw FormatException('GLB chunk at $offset overruns the file.');
    }
    switch (type) {
      case _jsonChunkType when jsonChunk == null:
        jsonChunk = Uint8List.sublistView(glb, start, end);
      case _binChunkType when binChunk == null:
        binChunk = Uint8List.sublistView(glb, start, end);
      default:
        // An extension chunk we would silently drop by rewriting the container.
        return null;
    }
    offset = end;
  }
  if (jsonChunk == null) {
    return null;
  }

  final gltf = jsonDecode(utf8.decode(jsonChunk));
  if (gltf is! Map<String, dynamic>) {
    return null;
  }
  final images = gltf['images'];
  if (images is! List || !images.any(_hasDataUri)) {
    return null;
  }

  final buffers = (gltf['buffers'] ??= <Object?>[]) as List<dynamic>;
  if (buffers.length > 1) {
    return null; // Multi-buffer GLBs are not what this pipeline produces.
  }
  if (buffers.isEmpty) {
    buffers.add(<String, Object?>{'byteLength': 0});
  }
  final buffer = buffers.first;
  if (buffer is! Map<String, dynamic> || buffer['uri'] != null) {
    return null; // An external or data-URI buffer is not ours to rewrite.
  }
  final bufferViews = (gltf['bufferViews'] ??= <Object?>[]) as List<dynamic>;

  final bin = BytesBuilder()..add(binChunk ?? Uint8List(0));
  for (final image in images) {
    if (!_hasDataUri(image)) {
      continue;
    }
    final entry = image as Map<String, dynamic>;
    final uri = entry['uri'] as String;
    final marker = uri.indexOf(';base64,');
    if (marker < 0) {
      return null; // A percent-encoded data URI; decoding it is out of scope.
    }
    final payload = base64Decode(uri.substring(marker + ';base64,'.length));
    final mimeType = _sniffMimeType(payload);
    if (mimeType == null) {
      return null; // Not a format glTF core allows; leave the file alone.
    }

    _padTo4(bin, 0);
    bufferViews.add(<String, Object?>{
      'buffer': 0,
      'byteOffset': bin.length,
      'byteLength': payload.length,
    });
    bin.add(payload);
    entry.remove('uri');
    entry['bufferView'] = bufferViews.length - 1;
    entry['mimeType'] = mimeType;
  }

  _padTo4(bin, 0);
  final binBytes = bin.takeBytes();
  buffer['byteLength'] = binBytes.length;

  final jsonBytes = utf8.encode(jsonEncode(gltf));
  final jsonPadding = (4 - jsonBytes.length % 4) % 4;
  final jsonLength = jsonBytes.length + jsonPadding;
  final total = 12 + 8 + jsonLength + 8 + binBytes.length;

  final out = Uint8List(total);
  final view = ByteData.sublistView(out);
  view.setUint32(0, _glbMagic, Endian.little);
  view.setUint32(4, 2, Endian.little);
  view.setUint32(8, total, Endian.little);
  view.setUint32(12, jsonLength, Endian.little);
  view.setUint32(16, _jsonChunkType, Endian.little);
  out.setRange(20, 20 + jsonBytes.length, jsonBytes);
  // The JSON chunk pads with spaces, the BIN chunk with zeroes.
  out.fillRange(20 + jsonBytes.length, 20 + jsonLength, 0x20);
  final binHeader = 20 + jsonLength;
  view.setUint32(binHeader, binBytes.length, Endian.little);
  view.setUint32(binHeader + 4, _binChunkType, Endian.little);
  out.setRange(binHeader + 8, total, binBytes);
  return out;
}

bool _hasDataUri(Object? image) {
  final uri = image is Map<String, dynamic> ? image['uri'] : null;
  return uri is String && uri.startsWith('data:');
}

/// Never trust the declared type: the exporter that ships JPEG bytes under
/// `data:image/png` is exactly the case this whole function exists for.
String? _sniffMimeType(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  return null;
}

void _padTo4(BytesBuilder builder, int fill) {
  final padding = (4 - builder.length % 4) % 4;
  if (padding > 0) {
    builder.add(Uint8List(padding)..fillRange(0, padding, fill));
  }
}
