import '../services/langflow_service.dart';

const defaultLangflowBaseUrl = 'http://127.0.0.1:7860';

class LangflowConfigurationResult {
  const LangflowConfigurationResult._({
    required this.configuration,
    required this.error,
  });

  final LangflowConfiguration? configuration;
  final String? error;

  bool get hasError => error != null;
}

class LangflowConfiguration {
  const LangflowConfiguration._({
    required this.runUri,
    required this.apiKey,
  });

  final Uri runUri;
  final String apiKey;

  static LangflowConfigurationResult fromEnvironment() {
    const baseUrl = String.fromEnvironment(
      'LANGFLOW_BASE_URL',
      defaultValue: defaultLangflowBaseUrl,
    );
    const flowId = String.fromEnvironment('LANGFLOW_FLOW_ID');
    const apiKey = String.fromEnvironment('LANGFLOW_API_KEY');
    const runEndpoint = String.fromEnvironment('LANGFLOW_RUN_ENDPOINT');

    return fromRawValues(
      baseUrl: baseUrl,
      flowId: flowId,
      apiKey: apiKey,
      runEndpoint: runEndpoint,
    );
  }

  static LangflowConfigurationResult fromRawValues({
    required String? baseUrl,
    required String? flowId,
    required String? apiKey,
    required String? runEndpoint,
  }) {
    final trimmedApiKey = apiKey?.trim() ?? '';
    if (trimmedApiKey.isEmpty) {
      return const LangflowConfigurationResult._(
        configuration: null,
        error:
            'Missing LANGFLOW_API_KEY. Provide it with --dart-define=LANGFLOW_API_KEY=... '
            'and rebuild the app.',
      );
    }

    final trimmedRunEndpoint = runEndpoint?.trim() ?? '';
    if (trimmedRunEndpoint.isNotEmpty) {
      final runUri = Uri.tryParse(trimmedRunEndpoint);
      final isValidRunUri =
          runUri != null &&
          runUri.hasScheme &&
          (runUri.scheme == 'http' || runUri.scheme == 'https') &&
          runUri.host.isNotEmpty;

      if (!isValidRunUri) {
        return const LangflowConfigurationResult._(
          configuration: null,
          error:
              'LANGFLOW_RUN_ENDPOINT must be an absolute http(s) URL such as '
              'http://127.0.0.1:7860/api/v1/run/<flow-id>?stream=false.',
        );
      }

      return LangflowConfigurationResult._(
        configuration: LangflowConfiguration._(
          runUri: runUri,
          apiKey: trimmedApiKey,
        ),
        error: null,
      );
    }

    final trimmedFlowId = flowId?.trim() ?? '';
    if (trimmedFlowId.isEmpty) {
      return const LangflowConfigurationResult._(
        configuration: null,
        error:
            'Missing LANGFLOW_FLOW_ID. Provide it with --dart-define=LANGFLOW_FLOW_ID=... '
            'or set LANGFLOW_RUN_ENDPOINT to the full run URL.',
      );
    }

    final trimmedBaseUrl = baseUrl?.trim() ?? '';
    final baseUri = Uri.tryParse(trimmedBaseUrl);
    final isValidBaseUri =
        baseUri != null &&
        baseUri.hasScheme &&
        (baseUri.scheme == 'http' || baseUri.scheme == 'https') &&
        baseUri.host.isNotEmpty;
    if (!isValidBaseUri) {
      return const LangflowConfigurationResult._(
        configuration: null,
        error:
            'LANGFLOW_BASE_URL must be an absolute http(s) URL such as '
            'http://127.0.0.1:7860 (desktop/adb reverse) or '
            'http://10.0.2.2:7860 (Android emulator).',
      );
    }

    final runUri = LangFlowService.buildRunUri(baseUri: baseUri, flowId: trimmedFlowId);
    return LangflowConfigurationResult._(
      configuration: LangflowConfiguration._(runUri: runUri, apiKey: trimmedApiKey),
      error: null,
    );
  }
}