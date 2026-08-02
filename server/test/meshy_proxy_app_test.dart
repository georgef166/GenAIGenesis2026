import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genai_server/src/meshy_proxy_app.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('MeshyProxyApp', () {
    test('rejects an empty prompt', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{'prompt': '   '}),
        ),
      );

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], contains('non-empty string'));
    });

    test('rejects an unknown generation kind', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'kind': 'galaxy',
          }),
        ),
      );

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], contains('"object"'));
    });

    test('rejects a world generation without a photo', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a sunlit alpine meadow',
            'kind': 'world',
          }),
        ),
      );

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], contains('imageBase64'));
    });

    test('forwards the uploaded photo to the backend intact', () async {
      final api = _FakeMeshyApi();
      final app = MeshyProxyApp(meshyApi: api, pollInterval: Duration.zero);
      final imageBase64 = base64Encode(
        List<int>.generate(4096, (index) => index % 256),
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a sunlit alpine meadow',
            'kind': 'world',
            'imageBase64': imageBase64,
          }),
        ),
      );

      expect(createResponse.statusCode, 202);
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;
      await app.waitForJob(jobId);

      expect(api.lastKind, 'world');
      expect(api.lastImageBase64, imageBase64);
    });

    test('clamps world steps before forwarding them', () async {
      final api = _FakeMeshyApi();
      final app = MeshyProxyApp(meshyApi: api, pollInterval: Duration.zero);

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a sunlit alpine meadow',
            'kind': 'world',
            'imageBase64': 'AA==',
            'steps': 2,
          }),
        ),
      );
      final jobId =
          (jsonDecode(await response.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;
      await app.waitForJob(jobId);

      expect(api.lastSteps, 10);
    });

    test('rejects object generation when its backend is absent', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      expect(await response.readAsString(), contains('not configured'));
    });

    test('rejects a photo over the 8 MB decoded cap', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());
      // 12 MB of base64 decodes to 9 MB, so the length check alone rejects it
      // without ever allocating the decoded bytes.
      final oversized = 'A' * (12 * 1024 * 1024);

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a sunlit alpine meadow',
            'kind': 'world',
            'imageBase64': oversized,
          }),
        ),
      );

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], contains('8 MB'));
    });

    test('runs a generation task to completion', () async {
      final api = _FakeMeshyApi();
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: api,
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );

      expect(createResponse.statusCode, 202);
      final createdJob =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;
      final jobId = createdJob['jobId'] as String;
      expect(createdJob['kind'], 'object');

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final completedJob =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(statusResponse.statusCode, 200);
      expect(api.lastKind, 'object');
      expect(completedJob['status'], 'completed');
      expect(completedJob['stage'], 'preview');
      expect(completedJob['previewTaskId'], 'task-1');
      expect(completedJob['refineTaskId'], isNull);
      expect(completedJob['activeTaskId'], 'task-1');
      expect(completedJob['meshyStatus'], 'succeeded');
      expect(completedJob['progress'], 100.0);
      expect(
        completedJob['glbUrl'],
        'http://localhost/api/meshy/asset/$jobId/model.glb',
      );
      expect(completedJob['panoramaUrl'], isNull);
      expect(completedJob['thumbnailUrl'], 'https://example.com/preview.png');
      expect(completedJob['createdAt'], isNotNull);
      expect(completedJob['updatedAt'], isNotNull);
      expect(completedJob['error'], isNull);
    });

    test('polling does not clear fields it did not update', () async {
      // Regression: `_updateJob` used to default its optional parameters to a
      // plain `null` and forward them unconditionally, so every poll wiped the
      // task id and thumbnail that only the create call ever set.
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _FakeMeshyApi(),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final job =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      // Both were set by `createTask` only; the two polls never mention them.
      expect(job['previewTaskId'], 'task-1');
      expect(job['thumbnailUrl'], 'https://example.com/preview.png');
    });

    test('streams assets and rewrites URLs onto the requested host', () async {
      final payload = List<int>.generate(64 * 1024, (index) => index % 256);
      final assetServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => assetServer.close(force: true));
      unawaited(
        assetServer.forEach((request) async {
          request.response.headers.contentType = ContentType(
            'model',
            'gltf-binary',
          );
          request.response.add(payload);
          await request.response.close();
        }),
      );

      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _FakeMeshyApi(
          glbUrl:
              'http://${assetServer.address.host}:${assetServer.port}/upstream.glb',
        ),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://192.168.1.5:8080/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;
      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request(
          'GET',
          Uri.parse('http://192.168.1.5:8080/api/meshy/generate/$jobId'),
        ),
      );
      final job =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;
      final glbUrl = job['glbUrl'] as String;

      // The phone can never reach the backend, so the URL must be this proxy's.
      expect(
        glbUrl,
        'http://192.168.1.5:8080/api/meshy/asset/$jobId/model.glb',
      );

      final assetResponse = await app.handler(
        Request('GET', Uri.parse(glbUrl)),
      );
      expect(assetResponse.statusCode, 200);
      expect(assetResponse.headers['content-type'], 'model/gltf-binary');
      final streamedBytes = await assetResponse.read().fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      expect(streamedBytes, payload);

      final unknownAsset = await app.handler(
        Request(
          'GET',
          Uri.parse('http://192.168.1.5:8080/api/meshy/asset/$jobId/nope.glb'),
        ),
      );
      expect(unknownAsset.statusCode, 404);
    });

    test('adapts Hunyuan3D and streams its decoded GLB', () async {
      final glb = <int>[
        0x67, 0x6c, 0x54, 0x46, // magic: glTF
        2, 0, 0, 0, // version
        12, 0, 0, 0, // total length
      ];
      Map<String, dynamic>? sendBody;
      final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => backend.close(force: true));
      unawaited(
        backend.forEach((request) async {
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/send') {
            final requestBytes = await request.fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            sendBody =
                jsonDecode(utf8.decode(requestBytes)) as Map<String, dynamic>;
            request.response.write(
              jsonEncode(<String, Object?>{'uid': 'task-object-1'}),
            );
          } else {
            request.response.write(
              jsonEncode(<String, Object?>{
                'status': 'completed',
                'model_base64': base64Encode(glb),
              }),
            );
          }
          await request.response.close();
        }),
      );

      final assetDirectory = await Directory.systemTemp.createTemp(
        'hunyuan-api-test-',
      );
      addTearDown(() => assetDirectory.delete(recursive: true));
      final objectApi = Hunyuan3dHttpApi(
        baseUri: Uri.parse('http://${backend.address.host}:${backend.port}'),
        assetDirectory: assetDirectory,
      );
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: objectApi,
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
            'steps': 40,
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;
      await app.waitForJob(jobId);

      expect(sendBody?['image'], 'AA==');
      expect(sendBody?['texture'], isTrue);
      expect(sendBody, isNot(contains('steps')));

      final jobResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final job =
          jsonDecode(await jobResponse.readAsString()) as Map<String, dynamic>;
      final assetResponse = await app.handler(
        Request('GET', Uri.parse(job['glbUrl'] as String)),
      );
      expect(assetResponse.statusCode, HttpStatus.ok);
      expect(await assetResponse.read().expand((chunk) => chunk).toList(), glb);
    });

    test('retries transient poll failures instead of failing the job', () async {
      // Regression: one dropped read over the SSH tunnel used to abandon a job
      // the A100 was still generating — the GPU finished, the client was told
      // it had failed, and the artifacts were unreachable.
      final api = _FakeMeshyApi(failCount: 4);
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: api,
        pollInterval: Duration.zero,
        pollRetryBackoff: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final job =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(job['status'], 'completed');
      expect(job['error'], isNull);
      expect(
        job['glbUrl'],
        'http://localhost/api/meshy/asset/$jobId/model.glb',
      );
    });

    test('gives up after a sustained run of poll failures', () async {
      final api = _FakeMeshyApi(failCount: 99);
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: api,
        pollInterval: Duration.zero,
        pollRetryBackoff: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
                  as Map<String, dynamic>)['jobId']
              as String;

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final job =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(job['status'], 'error');
      // The message has to name the run, not just blame the last exception.
      expect(job['error'], contains('5 consecutive polls failed'));
      expect(api.getTaskCalls, 5);
    });

    test(
      'fails fast when the backend reports a failed task',
      () async {
        // A 30s backoff makes any retry hang the test: this state is
        // terminal and must never be waited on.
        final api = _FakeMeshyApi(
          taskStates: <MeshyTask>[
            const MeshyTask(
              id: 'task-1',
              status: 'failed',
              errorMessage: 'Prompt violated moderation rules.',
            ),
          ],
        );
        final app = MeshyProxyApp(
          meshyApi: _FakeMeshyApi(),
          objectApi: api,
          pollInterval: Duration.zero,
          pollRetryBackoff: const Duration(seconds: 30),
        );

        final createResponse = await app.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/meshy/generate'),
            body: jsonEncode(<String, Object?>{
              'prompt': 'blocked prompt',
              'imageBase64': 'AA==',
            }),
          ),
        );
        final jobId =
            (jsonDecode(await createResponse.readAsString())
                    as Map<String, dynamic>)['jobId']
                as String;

        await app.waitForJob(jobId);

        final statusResponse = await app.handler(
          Request(
            'GET',
            Uri.parse('http://localhost/api/meshy/generate/$jobId'),
          ),
        );
        final job =
            jsonDecode(await statusResponse.readAsString())
                as Map<String, dynamic>;

        expect(job['status'], 'error');
        expect(job['error'], contains('moderation'));
        expect(api.getTaskCalls, 1);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'fails fast when the backend has lost the task',
      () async {
        final api = _FakeMeshyApi(
          failCount: 99,
          failure: const MeshyHttpException(
            statusCode: 404,
            message: 'Task not found.',
          ),
        );
        final app = MeshyProxyApp(
          meshyApi: _FakeMeshyApi(),
          objectApi: api,
          pollInterval: Duration.zero,
          pollRetryBackoff: const Duration(seconds: 30),
        );

        final createResponse = await app.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/meshy/generate'),
            body: jsonEncode(<String, Object?>{
              'prompt': 'a stone fox statue',
              'imageBase64': 'AA==',
            }),
          ),
        );
        final jobId =
            (jsonDecode(await createResponse.readAsString())
                    as Map<String, dynamic>)['jobId']
                as String;

        await app.waitForJob(jobId);

        final statusResponse = await app.handler(
          Request(
            'GET',
            Uri.parse('http://localhost/api/meshy/generate/$jobId'),
          ),
        );
        final job =
            jsonDecode(await statusResponse.readAsString())
                as Map<String, dynamic>;

        expect(job['status'], 'error');
        expect(job['error'], 'Task not found.');
        expect(api.getTaskCalls, 1);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('surfaces backend task failures', () async {
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _FakeMeshyApi(
          taskStates: <MeshyTask>[
            const MeshyTask(
              id: 'task-1',
              status: 'failed',
              errorMessage: 'Prompt violated moderation rules.',
            ),
          ],
        ),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'blocked prompt',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final createdJob =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;
      final jobId = createdJob['jobId'] as String;

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final failedJob =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(failedJob['status'], 'error');
      expect(failedJob['error'], contains('moderation'));
      expect(failedJob['glbUrl'], isNull);
    });

    test('exposes live backend progress on in-flight jobs', () async {
      final previewRelease = Completer<void>();
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _ControlledMeshyApi(previewRelease: previewRelease),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a bronze owl statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final createdJob =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;
      final jobId = createdJob['jobId'] as String;

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final inFlightJob =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(inFlightJob['status'], 'previewing');
      expect(inFlightJob['stage'], 'preview');
      expect(inFlightJob['activeTaskId'], 'task-1');
      expect(inFlightJob['meshyStatus'], 'running');
      expect(inFlightJob['progress'], 42.0);
      expect(inFlightJob['updatedAt'], isNotNull);

      previewRelease.complete();
      await app.waitForJob(jobId);
    });

    test('rejects a prompt over the length cap', () async {
      final app = MeshyProxyApp(meshyApi: _FakeMeshyApi());

      final response = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a' * 1001,
            'kind': 'world',
            'imageBase64': 'AA==',
          }),
        ),
      );

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], contains('at most 1000 characters'));
    });

    test('hides transport failure detail from the client', () async {
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _UnreachableMeshyApi(),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{
            'prompt': 'a stone fox statue',
            'imageBase64': 'AA==',
          }),
        ),
      );
      final jobId =
          (jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>)['jobId']
          as String;
      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final job =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(job['status'], 'error');
      expect(job['error'], contains('Check the server logs'));
      expect(job['error'], isNot(contains('127.0.0.1')));
      expect(job['error'], isNot(contains('SocketException')));
    });

    test('evicts terminal jobs older than the retention window', () async {
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        objectApi: _FakeMeshyApi(),
        pollInterval: Duration.zero,
        jobRetention: Duration.zero,
      );

      Future<String> generate() async {
        final response = await app.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/meshy/generate'),
            body: jsonEncode(<String, Object?>{
              'prompt': 'a stone fox statue',
              'imageBase64': 'AA==',
            }),
          ),
        );
        return (jsonDecode(await response.readAsString())
                as Map<String, dynamic>)['jobId']
            as String;
      }

      final firstJobId = await generate();
      await app.waitForJob(firstJobId);

      // The second create sweeps the first, which is terminal and past a
      // zero-length retention window.
      final secondJobId = await generate();
      await app.waitForJob(secondJobId);

      final evicted = await app.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/meshy/generate/$firstJobId'),
        ),
      );
      expect(evicted.statusCode, 404);

      final kept = await app.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/meshy/generate/$secondJobId'),
        ),
      );
      expect(kept.statusCode, 200);
    });

    test('rejects malformed create responses with a clear error', () async {
      expect(
        () => MeshyCreatedTask.fromJson(<String, dynamic>{'id': 'task-1'}),
        throwsA(
          isA<MeshyHttpException>().having(
            (MeshyHttpException error) => error.message,
            'message',
            contains('"task_id"'),
          ),
        ),
      );
    });
  });
}

class _FakeMeshyApi implements MeshyApi {
  _FakeMeshyApi({
    List<MeshyTask>? taskStates,
    String glbUrl = 'https://backend.invalid/generated.glb',
    this.failCount = 0,
    Object failure = const HttpException(
      'Connection closed before full header was received',
    ),
  }) : _failure = failure,
       _taskStates =
           taskStates ??
           <MeshyTask>[
             const MeshyTask(id: 'task-1', status: 'running', progress: 10.0),
             MeshyTask(
               id: 'task-1',
               status: 'succeeded',
               progress: 100.0,
               glbUrl: glbUrl,
             ),
           ];

  final List<MeshyTask> _taskStates;

  /// How many leading `getTask` calls throw [_failure] before the task states
  /// start being served.
  final int failCount;
  final Object _failure;
  int _cursor = 0;
  int getTaskCalls = 0;
  String? lastKind;
  String? lastImageBase64;
  int? lastSteps;

  @override
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  }) async {
    lastKind = kind;
    lastImageBase64 = imageBase64;
    lastSteps = steps;
    return const MeshyCreatedTask(
      taskId: 'task-1',
      thumbnailUrl: 'https://example.com/preview.png',
    );
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    getTaskCalls++;
    if (getTaskCalls <= failCount) {
      throw _failure;
    }
    if (_cursor >= _taskStates.length) {
      return _taskStates.last;
    }
    return _taskStates[_cursor++];
  }
}

/// Stands in for a backend whose SSH tunnel is down: the raw exception text
/// names the loopback host and port the phone must never see.
class _UnreachableMeshyApi implements MeshyApi {
  @override
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  }) async {
    throw const SocketException(
      'Connection refused, address = 127.0.0.1, port = 8771',
    );
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    throw StateError('never reached');
  }
}

class _ControlledMeshyApi implements MeshyApi {
  _ControlledMeshyApi({required this.previewRelease});

  final Completer<void> previewRelease;
  int _pollCount = 0;

  @override
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  }) async {
    return const MeshyCreatedTask(taskId: 'task-1');
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    if (taskId != 'task-1') {
      throw StateError('No controlled state configured for task "$taskId".');
    }

    _pollCount++;
    if (_pollCount == 1) {
      return const MeshyTask(id: 'task-1', status: 'running', progress: 42.0);
    }

    await previewRelease.future;
    return const MeshyTask(
      id: 'task-1',
      status: 'succeeded',
      progress: 100.0,
      glbUrl: 'https://backend.invalid/generated.glb',
    );
  }
}
