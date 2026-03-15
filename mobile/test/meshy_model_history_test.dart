import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genai/src/meshy_model_history.dart';
import 'package:genai/src/meshy_proxy_client.dart';

void main() {
  group('MeshyModelHistoryStore', () {
    late Directory tempDirectory;
    late MeshyModelHistoryStore store;
    HttpServer? server;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'meshy-model-history-test',
      );
      store = MeshyModelHistoryStore(
        documentsDirectoryLoader: () async => tempDirectory,
        maxEntries: 2,
      );
    });

    tearDown(() async {
      store.close();
      await server?.close(force: true);
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test(
      'caches a completed job and reloads it from the local index',
      () async {
        server = await _startTestServer(<int>[1, 2, 3, 4]);

        final result = await store.cacheCompletedJob(
          job: MeshyGenerationJob(
            jobId: 'job-1',
            status: MeshyJobStatus.completed,
            prompt: 'a carved fox statue',
            glbUrl: _serverUri(server!, '/job-1.glb').toString(),
            createdAt: DateTime.utc(2026, 3, 15, 12),
            updatedAt: DateTime.utc(2026, 3, 15, 12, 5),
          ),
        );

        final records = await store.loadRecords();
        expect(records, hasLength(1));
        expect(records.single.id, 'job-1');
        expect(records.single.prompt, 'a carved fox statue');
        expect(records.single.localRelativePath, 'meshy_models/job-1.glb');
        expect(result.activeModel.isPersisted, isTrue);
        expect(
          File('${tempDirectory.path}/meshy_models/job-1.glb').existsSync(),
          isTrue,
        );
      },
    );

    test('drops history entries whose cached GLB is missing', () async {
      final cacheDirectory = Directory('${tempDirectory.path}/meshy_models')
        ..createSync(recursive: true);
      final indexFile = File('${cacheDirectory.path}/history.json');
      await indexFile.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'records': <Map<String, Object?>>[
            MeshyModelRecord(
              id: 'job-1',
              prompt: 'missing model',
              localRelativePath: 'meshy_models/job-1.glb',
              originalGlbUrl: 'https://example.com/job-1.glb',
              createdAt: DateTime.utc(2026, 3, 15, 12),
              updatedAt: DateTime.utc(2026, 3, 15, 12),
              lastUsedAt: DateTime.utc(2026, 3, 15, 12),
            ).toJson(),
          ],
        }),
      );

      final records = await store.loadRecords();
      expect(records, isEmpty);

      final decoded = jsonDecode(await indexFile.readAsString());
      expect(decoded['records'], isEmpty);
    });

    test(
      'prunes the oldest cached models when the history exceeds the limit',
      () async {
        server = await _startTestServer(<int>[9, 8, 7, 6]);

        await store.cacheCompletedJob(
          job: MeshyGenerationJob(
            jobId: 'job-1',
            status: MeshyJobStatus.completed,
            prompt: 'first model',
            glbUrl: _serverUri(server!, '/job-1.glb').toString(),
            createdAt: DateTime.utc(2026, 3, 15, 10),
            updatedAt: DateTime.utc(2026, 3, 15, 10),
          ),
        );
        await store.cacheCompletedJob(
          job: MeshyGenerationJob(
            jobId: 'job-2',
            status: MeshyJobStatus.completed,
            prompt: 'second model',
            glbUrl: _serverUri(server!, '/job-2.glb').toString(),
            createdAt: DateTime.utc(2026, 3, 15, 11),
            updatedAt: DateTime.utc(2026, 3, 15, 11),
          ),
        );
        await store.cacheCompletedJob(
          job: MeshyGenerationJob(
            jobId: 'job-3',
            status: MeshyJobStatus.completed,
            prompt: 'third model',
            glbUrl: _serverUri(server!, '/job-3.glb').toString(),
            createdAt: DateTime.utc(2026, 3, 15, 12),
            updatedAt: DateTime.utc(2026, 3, 15, 12),
          ),
        );

        final records = await store.loadRecords();
        expect(records.map((record) => record.id).toList(), <String>[
          'job-3',
          'job-2',
        ]);
        expect(
          File('${tempDirectory.path}/meshy_models/job-1.glb').existsSync(),
          isFalse,
        );
      },
    );

    test('uses the original Meshy URL for Android persisted placement', () {
      final record = MeshyModelRecord(
        id: 'job-android',
        prompt: 'a bronze fox',
        localRelativePath: 'meshy_models/job-android.glb',
        originalGlbUrl: 'https://example.com/job-android.glb',
        createdAt: DateTime.utc(2026, 3, 15, 12),
        updatedAt: DateTime.utc(2026, 3, 15, 12),
        lastUsedAt: DateTime.utc(2026, 3, 15, 12),
      );

      final model = MeshyActiveModel.fromRecord(
        record,
        runtime: MeshyPlacementRuntime.android,
      );

      expect(model.isPersisted, isTrue);
      expect(model.nodeType, NodeType.webGLB);
      expect(model.nodeUri, record.originalGlbUrl);
      expect(model.hasRetryPlacementSource, isFalse);
    });

    test('uses cached local GLB first on iOS and can fall back to remote', () {
      final record = MeshyModelRecord(
        id: 'job-ios',
        prompt: 'a brass owl',
        localRelativePath: 'meshy_models/job-ios.glb',
        originalGlbUrl: 'https://example.com/job-ios.glb',
        createdAt: DateTime.utc(2026, 3, 15, 12),
        updatedAt: DateTime.utc(2026, 3, 15, 12),
        lastUsedAt: DateTime.utc(2026, 3, 15, 12),
      );

      final model = MeshyActiveModel.fromRecord(
        record,
        runtime: MeshyPlacementRuntime.iOS,
      );
      final fallback = model.fallbackAfterPlacementFailure();

      expect(model.nodeType, NodeType.fileSystemAppFolderGLB);
      expect(model.nodeUri, record.localRelativePath);
      expect(model.hasRetryPlacementSource, isTrue);
      expect(fallback, isNotNull);
      expect(fallback!.nodeType, NodeType.webGLB);
      expect(fallback.nodeUri, record.originalGlbUrl);
      expect(fallback.hasRetryPlacementSource, isFalse);
    });
  });
}

Future<HttpServer> _startTestServer(List<int> bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(bytes);
      await request.response.close();
    }),
  );
  return server;
}

Uri _serverUri(HttpServer server, String path) {
  return Uri.parse('http://${server.address.host}:${server.port}$path');
}
