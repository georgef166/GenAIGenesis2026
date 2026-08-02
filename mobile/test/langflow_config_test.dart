import 'package:flutter_test/flutter_test.dart';
import 'package:genai/config/langflow_config.dart';

void main() {
  test('uses full LANGFLOW_RUN_ENDPOINT when provided', () {
    const endpoint = 'http://127.0.0.1:7860/api/v1/run/custom-flow?stream=false';

    final result = LangflowConfiguration.fromRawValues(
      baseUrl: null,
      flowId: null,
      apiKey: 'test-key',
      runEndpoint: endpoint,
    );

    expect(result.error, isNull);
    expect(result.configuration, isNotNull);
    expect(result.configuration!.runUri, Uri.parse(endpoint));
    expect(result.configuration!.apiKey, 'test-key');
  });

  test('accepts run endpoint even when flow id is missing', () {
    final result = LangflowConfiguration.fromRawValues(
      baseUrl: 'http://127.0.0.1:7860',
      flowId: '',
      apiKey: 'test-key',
      runEndpoint: 'http://127.0.0.1:7860/api/v1/run/override-id',
    );

    expect(result.error, isNull);
    expect(result.configuration, isNotNull);
  });

  test('rejects invalid run endpoint URL', () {
    final result = LangflowConfiguration.fromRawValues(
      baseUrl: 'http://127.0.0.1:7860',
      flowId: 'flow-id',
      apiKey: 'test-key',
      runEndpoint: 'not-a-url',
    );

    expect(result.configuration, isNull);
    expect(result.error, contains('LANGFLOW_RUN_ENDPOINT'));
  });
}
