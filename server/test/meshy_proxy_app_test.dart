import 'dart:async';
import 'dart:convert';

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

    test('runs preview and refine tasks to completion', () async {
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{'prompt': 'a stone fox statue'}),
        ),
      );

      expect(createResponse.statusCode, 202);
      final createdJob =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;
      final jobId = createdJob['jobId'] as String;

      await app.waitForJob(jobId);

      final statusResponse = await app.handler(
        Request('GET', Uri.parse('http://localhost/api/meshy/generate/$jobId')),
      );
      final completedJob =
          jsonDecode(await statusResponse.readAsString())
              as Map<String, dynamic>;

      expect(statusResponse.statusCode, 200);
      expect(completedJob['status'], 'completed');
      expect(completedJob['stage'], 'refine');
      expect(completedJob['previewTaskId'], 'preview-1');
      expect(completedJob['refineTaskId'], 'refine-1');
      expect(completedJob['activeTaskId'], 'refine-1');
      expect(completedJob['meshyStatus'], 'SUCCEEDED');
      expect(completedJob['progress'], 100.0);
      expect(completedJob['glbUrl'], 'https://example.com/generated.glb');
      expect(completedJob['thumbnailUrl'], 'https://example.com/preview.png');
      expect(completedJob['createdAt'], isNotNull);
      expect(completedJob['updatedAt'], isNotNull);
      expect(completedJob['error'], isNull);
    });

    test('surfaces Meshy task failures', () async {
      final app = MeshyProxyApp(
        meshyApi: _FakeMeshyApi(
          taskStates: <String, List<MeshyTask>>{
            'preview-1': <MeshyTask>[
              const MeshyTask(
                id: 'preview-1',
                status: 'FAILED',
                errorMessage: 'Prompt violated moderation rules.',
              ),
            ],
          },
        ),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{'prompt': 'blocked prompt'}),
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

    test('exposes live Meshy progress on in-flight jobs', () async {
      final previewRelease = Completer<void>();
      final app = MeshyProxyApp(
        meshyApi: _ControlledMeshyApi(previewRelease: previewRelease),
        pollInterval: Duration.zero,
      );

      final createResponse = await app.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/meshy/generate'),
          body: jsonEncode(<String, Object?>{'prompt': 'a bronze owl statue'}),
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
      expect(inFlightJob['activeTaskId'], 'preview-1');
      expect(inFlightJob['meshyStatus'], 'IN_PROGRESS');
      expect(inFlightJob['progress'], 42.0);
      expect(inFlightJob['updatedAt'], isNotNull);

      previewRelease.complete();
      await app.waitForJob(jobId);
    });

    test(
      'rejects malformed Meshy create responses with a clear error',
      () async {
        expect(
          () => MeshyCreatedTask.fromJson(<String, dynamic>{'id': 'preview-1'}),
          throwsA(
            isA<MeshyHttpException>().having(
              (MeshyHttpException error) => error.message,
              'message',
              contains('"result"'),
            ),
          ),
        );
      },
    );
  });
}

class _FakeMeshyApi implements MeshyApi {
  _FakeMeshyApi({Map<String, List<MeshyTask>>? taskStates})
    : _taskStates =
          taskStates ??
          <String, List<MeshyTask>>{
            'preview-1': <MeshyTask>[
              const MeshyTask(
                id: 'preview-1',
                status: 'SUCCEEDED',
                progress: 100.0,
                thumbnailUrl: 'https://example.com/preview.png',
              ),
            ],
            'refine-1': <MeshyTask>[
              const MeshyTask(
                id: 'refine-1',
                status: 'SUCCEEDED',
                progress: 100.0,
                thumbnailUrl: 'https://example.com/preview.png',
                glbUrl: 'https://example.com/generated.glb',
              ),
            ],
          };

  final Map<String, List<MeshyTask>> _taskStates;
  final Map<String, int> _cursors = <String, int>{};

  @override
  Future<MeshyCreatedTask> createPreviewTask(String prompt) async {
    return const MeshyCreatedTask(
      taskId: 'preview-1',
      thumbnailUrl: 'https://example.com/preview.png',
    );
  }

  @override
  Future<MeshyCreatedTask> createRefineTask({
    required String previewTaskId,
    required String prompt,
  }) async {
    return const MeshyCreatedTask(
      taskId: 'refine-1',
      thumbnailUrl: 'https://example.com/preview.png',
    );
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    final states = _taskStates[taskId];
    if (states == null || states.isEmpty) {
      throw StateError('No fake Meshy state configured for task "$taskId".');
    }

    final index = _cursors[taskId] ?? 0;
    if (index >= states.length) {
      return states.last;
    }

    _cursors[taskId] = index + 1;
    return states[index];
  }
}

class _ControlledMeshyApi implements MeshyApi {
  _ControlledMeshyApi({required this.previewRelease});

  final Completer<void> previewRelease;
  int _previewPollCount = 0;

  @override
  Future<MeshyCreatedTask> createPreviewTask(String prompt) async {
    return const MeshyCreatedTask(taskId: 'preview-1');
  }

  @override
  Future<MeshyCreatedTask> createRefineTask({
    required String previewTaskId,
    required String prompt,
  }) async {
    return const MeshyCreatedTask(taskId: 'refine-1');
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    if (taskId == 'preview-1') {
      _previewPollCount++;
      if (_previewPollCount == 1) {
        return const MeshyTask(
          id: 'preview-1',
          status: 'IN_PROGRESS',
          progress: 42.0,
          thumbnailUrl: 'https://example.com/preview.png',
        );
      }

      await previewRelease.future;
      return const MeshyTask(
        id: 'preview-1',
        status: 'SUCCEEDED',
        progress: 100.0,
        thumbnailUrl: 'https://example.com/preview.png',
      );
    }

    if (taskId == 'refine-1') {
      return const MeshyTask(
        id: 'refine-1',
        status: 'SUCCEEDED',
        progress: 100.0,
        thumbnailUrl: 'https://example.com/preview.png',
        glbUrl: 'https://example.com/generated.glb',
      );
    }

    throw StateError(
      'No controlled Meshy state configured for task "$taskId".',
    );
  }
}
