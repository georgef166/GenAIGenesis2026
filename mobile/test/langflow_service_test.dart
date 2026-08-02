import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:genai/services/langflow_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Uri testRunUri() => Uri.parse('http://127.0.0.1:7860/api/v1/run/flow?stream=false');

  String successEnvelope(String text) {
    return jsonEncode({
      'outputs': [
        {
          'outputs': [
            {
              'results': {
                'message': {'text': text},
              },
            },
          ],
        },
      ],
    });
  }

  const validFactsJson = '''
{
  "topic": "Space",
  "fact1": "f1",
  "fact2": "f2",
  "fact3": "f3",
  "fact4": "f4",
  "fact5": "f5",
  "fact6": "f6"
}
''';

  test('parses a successful Langflow response', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient((request) async {
        expect(request.url, testRunUri());
        expect(request.method, 'POST');
        expect(request.headers['x-api-key'], 'test-key');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['input_value'], 'solar system');
        expect(body['input_type'], 'chat');
        expect(body['output_type'], 'chat');

        return http.Response(successEnvelope(validFactsJson), 200);
      }),
    );

    final result = await service.fetchResearch('solar system');
    expect(result.topic, 'Space');
    expect(result.facts, ['f1', 'f2', 'f3', 'f4', 'f5', 'f6']);
  });

  test('parses fenced JSON in message text', () async {
    final fencedJson = '```json\n$validFactsJson\n```';
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response(successEnvelope(fencedJson), 200),
      ),
    );

    final result = await service.fetchResearch('oceans');
    expect(result.topic, 'Space');
  });

  test('rejects an empty topic', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient((_) async => http.Response('{}', 200)),
    );

    expect(
      () => service.fetchResearch('   '),
      throwsA(
        isA<LangFlowServiceException>().having(
          (e) => e.message,
          'message',
          contains('Please enter a topic'),
        ),
      ),
    );
  });

  test('handles 401 responses clearly', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'bad-key',
      client: MockClient((_) async => http.Response('unauthorized', 401)),
    );

    expect(
      () => service.fetchResearch('volcanoes'),
      throwsA(
        isA<LangFlowServiceException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('API key')),
      ),
    );
  });

  test('handles non-2xx server errors', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response('{"detail":"upstream failure"}', 500),
      ),
    );

    expect(
      () => service.fetchResearch('volcanoes'),
      throwsA(
        isA<LangFlowServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', contains('upstream failure')),
      ),
    );
  });

  test('handles timeout', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      timeout: const Duration(milliseconds: 20),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return http.Response(successEnvelope(validFactsJson), 200);
      }),
    );

    expect(
      () => service.fetchResearch('rainforests'),
      throwsA(
        isA<LangFlowServiceException>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('fails when outputs are missing', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient((_) async => http.Response('{"foo":"bar"}', 200)),
    );

    expect(
      () => service.fetchResearch('clouds'),
      throwsA(
        isA<LangFlowServiceException>().having(
          (e) => e.message,
          'message',
          contains('missing outputs'),
        ),
      ),
    );
  });

  test('fails on malformed JSON produced by the model', () async {
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response(successEnvelope('not-json-at-all'), 200),
      ),
    );

    expect(
      () => service.fetchResearch('rocks'),
      throwsA(
        isA<LangFlowServiceException>().having(
          (e) => e.message,
          'message',
          contains('not a JSON object'),
        ),
      ),
    );
  });

  test('fails when required fact fields are missing', () async {
    const missingFactJson = '{"topic":"Plants","fact1":"f1","fact2":"f2"}';
    final service = LangFlowService(
      runUri: testRunUri(),
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response(successEnvelope(missingFactJson), 200),
      ),
    );

    expect(
      () => service.fetchResearch('plants'),
      throwsA(
        isA<LangFlowServiceException>().having(
          (e) => e.message,
          'message',
          contains('missing required field'),
        ),
      ),
    );
  });
}
