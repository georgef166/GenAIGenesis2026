import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/research_result.dart';

class LangFlowService {
  LangFlowService({
    required this.apiKey,
    this.baseUrl,
    this.flowId,
    Uri? runUri,
    http.Client? client,
    Duration timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _timeout = timeout,
       _runUri = _withStreamFalse(
         runUri ??
             _buildRunUriFromParts(
               baseUrl: baseUrl,
               flowId: flowId,
             ),
       );

  final String? baseUrl;
  final String? flowId;
  final String apiKey;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;
  final Uri _runUri;

  static Uri buildRunUri({required Uri baseUri, required String flowId}) {
    final normalizedFlowId = flowId.trim();
    final safeFlowId = Uri.encodeComponent(normalizedFlowId);
    final runPath = '/api/v1/run/$safeFlowId';

    return baseUri.replace(
      path: _joinPath(baseUri.path, runPath),
      queryParameters: {'stream': 'false'},
    );
  }

  Future<ResearchResult> fetchResearch(String topic) async {
    final trimmedTopic = topic.trim();
    if (trimmedTopic.isEmpty) {
      throw const LangFlowServiceException('Please enter a topic before submitting.');
    }

    final requestBody = {
      'input_value': trimmedTopic,
      'input_type': 'chat',
      'output_type': 'chat',
    };

    late final http.Response response;
    try {
      response = await _client
          .post(
            _runUri,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
            },
            body: jsonEncode(requestBody),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const LangFlowServiceException(
        'The Langflow request timed out after 90 seconds. Please try again.',
      );
    } on SocketException {
      throw LangFlowServiceException(
        'Could not connect to Langflow at $_runUri. Verify the local server is running and reachable.',
      );
    } on http.ClientException catch (error) {
      final lower = error.message.toLowerCase();
      if (lower.contains('connection refused')) {
        throw LangFlowServiceException(
          'Langflow refused the connection at $_runUri. Verify the local server is running and reachable.',
        );
      }
      throw LangFlowServiceException('Langflow request failed: ${error.message}');
    }

    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      throw LangFlowServiceException(
        'Langflow rejected the API key (HTTP ${response.statusCode}). Check LANGFLOW_API_KEY.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LangFlowServiceException(
        'Langflow request failed with HTTP ${response.statusCode}: ${_summarizeServerError(response.body)}',
        statusCode: response.statusCode,
      );
    }

    final decoded = _decodeRootMap(response.body);
    final rawText = _extractMessageText(decoded);
    final cleanedJsonText = _cleanMarkdownBackticks(rawText);

    final resultJson = _decodeResultMap(cleanedJsonText);
    _validateResultFields(resultJson);
    return ResearchResult.fromJson(resultJson);
  }

  static Uri _buildRunUriFromParts({String? baseUrl, String? flowId}) {
    final trimmedBaseUrl = baseUrl?.trim() ?? '';
    final trimmedFlowId = flowId?.trim() ?? '';
    if (trimmedBaseUrl.isEmpty || trimmedFlowId.isEmpty) {
      throw const LangFlowServiceException(
        'Langflow configuration is incomplete. Provide either runUri or both baseUrl and flowId.',
      );
    }

    final parsedBase = Uri.tryParse(trimmedBaseUrl);
    final isValidBase =
        parsedBase != null &&
        parsedBase.hasScheme &&
        (parsedBase.scheme == 'http' || parsedBase.scheme == 'https') &&
        parsedBase.host.isNotEmpty;
    if (!isValidBase) {
      throw const LangFlowServiceException(
        'LANGFLOW_BASE_URL must be an absolute http(s) URL.',
      );
    }

    return buildRunUri(baseUri: parsedBase, flowId: trimmedFlowId);
  }

  static String _joinPath(String basePath, String appendedPath) {
    final trimmedBasePath = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final normalizedAppended = appendedPath.startsWith('/')
        ? appendedPath
        : '/$appendedPath';
    return '$trimmedBasePath$normalizedAppended';
  }

  static Uri _withStreamFalse(Uri uri) {
    final query = <String, String>{...uri.queryParameters};
    query['stream'] = 'false';
    return uri.replace(queryParameters: query);
  }

  Map<String, dynamic> _decodeRootMap(String responseBody) {
    final decoded = _tryDecodeJson(responseBody);
    if (decoded is! Map<String, dynamic>) {
      throw const LangFlowServiceException(
        'Langflow returned a malformed top-level response.',
      );
    }

    return decoded;
  }

  Map<String, dynamic> _decodeResultMap(String rawJsonText) {
    final decoded = _tryDecodeJson(rawJsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const LangFlowServiceException(
        'Langflow returned message text that is not a JSON object.',
      );
    }

    return decoded;
  }

  void _validateResultFields(Map<String, dynamic> json) {
    const keys = ['topic', 'fact1', 'fact2', 'fact3', 'fact4', 'fact5', 'fact6'];
    for (final key in keys) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw LangFlowServiceException(
          'Langflow response is missing required field "$key".',
        );
      }
    }
  }

  String _extractMessageText(Map<String, dynamic> data) {
    final payload =
        (data['data'] is Map<String, dynamic>) ? data['data'] as Map<String, dynamic> : data;

    final outputs = payload['outputs'];
    if (outputs is! List || outputs.isEmpty) {
      throw const LangFlowServiceException('Langflow response is missing outputs.');
    }

    final firstOutput = outputs.first;
    if (firstOutput is! Map<String, dynamic>) {
      throw const LangFlowServiceException('Langflow output item has an unexpected shape.');
    }

    final nestedOutputs = firstOutput['outputs'];
    if (nestedOutputs is! List || nestedOutputs.isEmpty) {
      throw const LangFlowServiceException('Langflow nested outputs are missing.');
    }

    final firstNestedOutput = nestedOutputs.first;
    if (firstNestedOutput is! Map<String, dynamic>) {
      throw const LangFlowServiceException(
        'Langflow nested output has an unexpected shape.',
      );
    }

    final results = firstNestedOutput['results'];
    if (results is! Map<String, dynamic>) {
      throw const LangFlowServiceException('Langflow results section is missing.');
    }

    final message = results['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message;
    }

    if (message is! Map<String, dynamic>) {
      throw const LangFlowServiceException('Langflow message section is missing.');
    }

    final text = message['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const LangFlowServiceException('Langflow message text is empty.');
    }

    return text;
  }

  String _summarizeServerError(String body) {
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      return 'empty response body';
    }

    try {
      final decoded = jsonDecode(trimmedBody);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['detail'] ?? decoded['message'] ?? decoded['error'];
        if (message != null) {
          return message.toString();
        }
      }
    } catch (_) {
      // Keep the plain response snippet below when JSON parsing fails.
    }

    return trimmedBody.length > 220
        ? '${trimmedBody.substring(0, 220)}...'
        : trimmedBody;
  }

  String _cleanMarkdownBackticks(String rawText) {
    var cleaned = rawText.trim();

    if (cleaned.startsWith('```')) {
      cleaned = cleaned.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
      cleaned = cleaned.replaceFirst(RegExp(r'\s*```$'), '');
    }

    cleaned = cleaned.replaceAll('```', '').trim();

    if (cleaned.toLowerCase().startsWith('json\n')) {
      cleaned = cleaned.substring(5).trim();
    }

    return cleaned;
  }

  Object? _tryDecodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

class LangFlowServiceException implements Exception {
  const LangFlowServiceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'LangFlowServiceException: $message';
  }
}
