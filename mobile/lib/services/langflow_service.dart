import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/research_result.dart';

class LangFlowService {
  LangFlowService({
    required this.baseUrl,
    required this.flowId,
    required this.appToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String flowId;
  final String appToken;
  final http.Client _client;

  Uri _runUri() => Uri.parse('$baseUrl/lf/$flowId/api/v1/run');

  Future<ResearchResult> fetchResearch(String topic) async {
    final trimmedTopic = topic.trim();
    if (trimmedTopic.isEmpty) {
      throw const FormatException('Please enter a topic before submitting.');
    }

    final response = await _client.post(
      _runUri(),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $appToken',
      },
      body: jsonEncode({
        'input_value': trimmedTopic,
        'input_type': 'chat',
        'output_type': 'chat',
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'LangFlow API failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected API response format from LangFlow.');
    }

    final rawText = _extractMessageText(decoded);
    final cleanedJsonText = _cleanMarkdownBackticks(rawText);
    final resultJson = jsonDecode(cleanedJsonText);

    if (resultJson is! Map<String, dynamic>) {
      throw const FormatException('LangFlow result is not a JSON object.');
    }

    return ResearchResult.fromJson(resultJson);
  }

  String _extractMessageText(Map<String, dynamic> data) {
    final outputs = data['outputs'];
    if (outputs is! List || outputs.isEmpty) {
      throw const FormatException('LangFlow output is missing outputs array.');
    }

    final firstOutput = outputs.first;
    if (firstOutput is! Map<String, dynamic>) {
      throw const FormatException('Unexpected first output format.');
    }

    final nestedOutputs = firstOutput['outputs'];
    if (nestedOutputs is! List || nestedOutputs.isEmpty) {
      throw const FormatException('Nested outputs are missing.');
    }

    final firstNestedOutput = nestedOutputs.first;
    if (firstNestedOutput is! Map<String, dynamic>) {
      throw const FormatException('Unexpected nested output format.');
    }

    final results = firstNestedOutput['results'];
    if (results is! Map<String, dynamic>) {
      throw const FormatException('Results section is missing.');
    }

    final message = results['message'];
    if (message is! Map<String, dynamic>) {
      throw const FormatException('Message section is missing.');
    }

    final text = message['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('Message text is empty.');
    }

    return text;
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

  void dispose() {
    _client.close();
  }
}
