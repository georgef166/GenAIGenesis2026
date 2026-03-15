import 'package:flutter_test/flutter_test.dart';
import 'package:genai/src/meshy_proxy_client.dart';

void main() {
  test('uses nixos proxy by default when no override is provided', () {
    final configuration = MeshyProxyConfiguration.fromRawValue(null);

    expect(configuration.error, isNull);
    expect(configuration.client, isNotNull);
    expect(configuration.client!.baseUri, Uri.parse('http://nixos:8080'));
  });

  test('uses the override URL when MESHY_PROXY_BASE_URL is provided', () {
    final configuration = MeshyProxyConfiguration.fromRawValue(
      'http://example.local:9000',
    );

    expect(configuration.error, isNull);
    expect(configuration.client, isNotNull);
    expect(
      configuration.client!.baseUri,
      Uri.parse('http://example.local:9000'),
    );
  });

  test('returns an error for an invalid proxy override URL', () {
    final configuration = MeshyProxyConfiguration.fromRawValue('not-a-url');

    expect(configuration.client, isNull);
    expect(configuration.error, contains('http://nixos:8080'));
  });

  test('parses a completed Meshy generation job payload', () {
    final job = MeshyGenerationJob.fromJson(<String, dynamic>{
      'jobId': 'job-123',
      'status': 'completed',
      'prompt': 'a jade fox statue',
      'stage': 'refine',
      'previewTaskId': 'preview-123',
      'refineTaskId': 'refine-123',
      'glbUrl': 'https://example.com/model.glb',
      'activeTaskId': 'refine-123',
      'meshyStatus': 'SUCCEEDED',
      'progress': 100,
      'meshyError': null,
      'thumbnailUrl': 'https://example.com/thumb.png',
      'error': null,
      'createdAt': '2026-03-14T05:26:08.000Z',
      'updatedAt': '2026-03-14T05:27:08.000Z',
    });

    expect(job.jobId, 'job-123');
    expect(job.status, MeshyJobStatus.completed);
    expect(job.stage, 'refine');
    expect(job.glbUrl, 'https://example.com/model.glb');
    expect(job.activeTaskId, 'refine-123');
    expect(job.meshyStatus, 'SUCCEEDED');
    expect(job.progress, 100);
    expect(job.thumbnailUrl, 'https://example.com/thumb.png');
    expect(job.updatedAt, DateTime.parse('2026-03-14T05:27:08.000Z').toUtc());
    expect(job.isTerminal, isTrue);
  });

  test('throws when the proxy payload is missing required fields', () {
    expect(
      () => MeshyGenerationJob.fromJson(<String, dynamic>{}),
      throwsA(isA<MeshyProxyException>()),
    );
  });
}
