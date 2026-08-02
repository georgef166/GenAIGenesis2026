import 'dart:convert';
import 'dart:typed_data';

import 'package:genai_server/src/glb_repack.dart';
import 'package:test/test.dart';

/// Bytes that start like a JPEG (`FF D8 FF E0 ... JFIF`) — the payload
/// Hunyuan3D ships under a `data:image/png` URI.
final _jpegPayload = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x02, 0x03, 0x04, // A 15-byte payload, so alignment has to be handled.
]);

void main() {
  group('repackGlbDataUriImages', () {
    test('moves a data-URI image into the BIN chunk with the sniffed type', () {
      // The payload is JPEG but the URI declares PNG, exactly as pygltflib
      // exports it.
      final input = _buildGlb(<String, Object?>{
        'asset': <String, Object?>{'version': '2.0'},
        'images': <Object?>[
          <String, Object?>{
            'uri': 'data:image/png;base64,${base64Encode(_jpegPayload)}',
          },
        ],
        'bufferViews': <Object?>[
          <String, Object?>{'buffer': 0, 'byteOffset': 0, 'byteLength': 6},
        ],
        'buffers': <Object?>[
          <String, Object?>{'byteLength': 6},
        ],
      }, bin: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 0, 0]));

      final output = repackGlbDataUriImages(input);

      expect(utf8.decode(output.sublist(0, 4)), 'glTF');
      final header = ByteData.sublistView(output);
      expect(header.getUint32(8, Endian.little), output.length);

      final chunks = _readChunks(output);
      for (final chunk in chunks) {
        expect(chunk.length % 4, 0, reason: 'chunk ${chunk.type} misaligned');
        expect(chunk.start % 4, 0, reason: 'chunk ${chunk.type} misaligned');
      }
      expect(chunks.map((chunk) => chunk.type), <int>[0x4E4F534A, 0x004E4942]);

      final gltf =
          jsonDecode(utf8.decode(chunks.first.bytes)) as Map<String, dynamic>;
      final image = (gltf['images'] as List).single as Map<String, dynamic>;
      expect(image.containsKey('uri'), isFalse);
      expect(image['mimeType'], 'image/jpeg');

      final bufferViews = gltf['bufferViews'] as List;
      final view = bufferViews[image['bufferView'] as int] as Map;
      expect(view['buffer'], 0);
      final bin = chunks.last.bytes;
      final offset = view['byteOffset'] as int;
      expect(view['byteLength'], _jpegPayload.length);
      expect(bin.sublist(offset, offset + _jpegPayload.length), _jpegPayload);

      // The pre-existing bufferView and its bytes survive untouched.
      expect(bufferViews.first, <String, Object?>{
        'buffer': 0,
        'byteOffset': 0,
        'byteLength': 6,
      });
      expect(bin.sublist(0, 6), <int>[1, 2, 3, 4, 5, 6]);
      expect((gltf['buffers'] as List).single, <String, Object?>{
        'byteLength': bin.length,
      });
    });

    test('creates a BIN chunk when the GLB has none', () {
      final input = _buildGlb(<String, Object?>{
        'asset': <String, Object?>{'version': '2.0'},
        'images': <Object?>[
          <String, Object?>{
            'uri': 'data:image/png;base64,${base64Encode(_jpegPayload)}',
          },
        ],
      });

      final chunks = _readChunks(repackGlbDataUriImages(input));

      expect(chunks.length, 2);
      final gltf =
          jsonDecode(utf8.decode(chunks.first.bytes)) as Map<String, dynamic>;
      final image = (gltf['images'] as List).single as Map<String, dynamic>;
      expect(image['bufferView'], 0);
      expect(chunks.last.bytes.sublist(0, _jpegPayload.length), _jpegPayload);
    });

    test('leaves a bufferView-backed GLB byte-identical', () {
      final input = _buildGlb(<String, Object?>{
        'asset': <String, Object?>{'version': '2.0'},
        'images': <Object?>[
          <String, Object?>{'bufferView': 0, 'mimeType': 'image/jpeg'},
        ],
        'bufferViews': <Object?>[
          <String, Object?>{'buffer': 0, 'byteOffset': 0, 'byteLength': 4},
        ],
        'buffers': <Object?>[
          <String, Object?>{'byteLength': 4},
        ],
      }, bin: Uint8List.fromList(<int>[9, 9, 9, 9]));

      expect(repackGlbDataUriImages(input), input);
    });

    test('returns unparseable input unchanged instead of throwing', () {
      final garbage = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(repackGlbDataUriImages(garbage), garbage);

      // Valid magic, but the JSON chunk claims more bytes than the file holds.
      final truncated = Uint8List.fromList(<int>[
        0x67, 0x6C, 0x54, 0x46, // glTF
        2, 0, 0, 0,
        24, 0, 0, 0,
        0xFF, 0xFF, 0, 0, // chunk length far past the end
        0x4A, 0x53, 0x4F, 0x4E,
        0x7B, 0x7D, 0x20, 0x20,
      ]);
      expect(repackGlbDataUriImages(truncated), truncated);
    });
  });
}

Uint8List _buildGlb(Map<String, Object?> gltf, {Uint8List? bin}) {
  final jsonBytes = utf8.encode(jsonEncode(gltf));
  final padding = (4 - jsonBytes.length % 4) % 4;
  final jsonLength = jsonBytes.length + padding;
  final total = 12 + 8 + jsonLength + (bin == null ? 0 : 8 + bin.length);

  final out = Uint8List(total);
  final view = ByteData.sublistView(out);
  view.setUint32(0, 0x46546C67, Endian.little);
  view.setUint32(4, 2, Endian.little);
  view.setUint32(8, total, Endian.little);
  view.setUint32(12, jsonLength, Endian.little);
  view.setUint32(16, 0x4E4F534A, Endian.little);
  out.setRange(20, 20 + jsonBytes.length, jsonBytes);
  out.fillRange(20 + jsonBytes.length, 20 + jsonLength, 0x20);
  if (bin != null) {
    final at = 20 + jsonLength;
    view.setUint32(at, bin.length, Endian.little);
    view.setUint32(at + 4, 0x004E4942, Endian.little);
    out.setRange(at + 8, total, bin);
  }
  return out;
}

List<_Chunk> _readChunks(Uint8List glb) {
  final view = ByteData.sublistView(glb);
  final chunks = <_Chunk>[];
  var offset = 12;
  while (offset + 8 <= glb.length) {
    final length = view.getUint32(offset, Endian.little);
    final type = view.getUint32(offset + 4, Endian.little);
    chunks.add(
      _Chunk(
        type: type,
        start: offset + 8,
        bytes: Uint8List.sublistView(glb, offset + 8, offset + 8 + length),
      ),
    );
    offset += 8 + length;
  }
  return chunks;
}

class _Chunk {
  _Chunk({required this.type, required this.start, required this.bytes});

  final int type;
  final int start;
  final Uint8List bytes;

  int get length => bytes.length;
}
