import 'dart:convert';
import 'dart:io';

class MeshyProxyConfiguration {
  const MeshyProxyConfiguration._({required this.client, required this.error});

  final MeshyProxyClient? client;
  final String? error;

  static MeshyProxyConfiguration fromEnvironment() {
    const rawValue = String.fromEnvironment('MESHY_PROXY_BASE_URL');
    return fromRawValue(rawValue);
  }

  static MeshyProxyConfiguration fromRawValue(String? rawValue) {
    final trimmed = rawValue?.trim() ?? '';
    if (trimmed.isEmpty) {
      return MeshyProxyConfiguration._(
        client: MeshyProxyClient(baseUri: Uri.parse('http://nixos:8080')),
        error: null,
      );
    }

    final uri = Uri.tryParse(trimmed);
    final isValid =
        uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!isValid) {
      return const MeshyProxyConfiguration._(
        client: null,
        error:
            'MESHY_PROXY_BASE_URL must be an absolute http(s) URL such as '
            'http://nixos:8080.',
      );
    }

    return MeshyProxyConfiguration._(
      client: MeshyProxyClient(baseUri: uri),
      error: null,
    );
  }
}

class MeshyProxyClient {
  MeshyProxyClient({required Uri baseUri, HttpClient? httpClient})
    : _baseUri = baseUri,
      _httpClient = httpClient ?? HttpClient();

  final Uri _baseUri;
  final HttpClient _httpClient;

  Uri get baseUri => _baseUri;

  Future<MeshyGenerationJob> createJob(String prompt) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      pathSegments: const <String>['api', 'meshy', 'generate'],
      body: <String, Object?>{'prompt': prompt},
    );
    return MeshyGenerationJob.fromJson(response);
  }

  Future<MeshyGenerationJob> getJob(String jobId) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      pathSegments: <String>['api', 'meshy', 'generate', jobId],
    );
    return MeshyGenerationJob.fromJson(response);
  }

  Future<Map<String, dynamic>> _sendJsonRequest({
    required String method,
    required List<String> pathSegments,
    Map<String, Object?>? body,
  }) async {
    final request = await _httpClient.openUrl(method, _buildUri(pathSegments));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
    }

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    final decodedBody = responseBody.isEmpty ? null : jsonDecode(responseBody);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw MeshyProxyException(_extractErrorMessage(decodedBody, response));
    }

    if (decodedBody is! Map<String, dynamic>) {
      throw const MeshyProxyException(
        'The local Meshy proxy returned an unexpected JSON payload.',
      );
    }

    return decodedBody;
  }

  Uri _buildUri(List<String> extraSegments) {
    final joinedSegments = <String>[
      ..._baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      ...extraSegments,
    ];

    return _baseUri.replace(pathSegments: joinedSegments);
  }

  String _extractErrorMessage(
    Object? decodedBody,
    HttpClientResponse response,
  ) {
    if (decodedBody is Map<String, dynamic>) {
      final error = decodedBody['error'];
      if (error is String && error.trim().isNotEmpty) {
        return error.trim();
      }
    }

    return 'The local Meshy proxy returned HTTP ${response.statusCode}.';
  }
}

enum MeshyJobStatus { submitting, previewing, refining, completed, error }

class MeshyGenerationJob {
  const MeshyGenerationJob({
    required this.jobId,
    required this.status,
    required this.prompt,
    this.stage,
    this.previewTaskId,
    this.refineTaskId,
    this.glbUrl,
    this.activeTaskId,
    this.meshyStatus,
    this.progress,
    this.meshyError,
    this.thumbnailUrl,
    this.error,
    this.createdAt,
    this.updatedAt,
  });

  final String jobId;
  final MeshyJobStatus status;
  final String prompt;
  final String? stage;
  final String? previewTaskId;
  final String? refineTaskId;
  final String? glbUrl;
  final String? activeTaskId;
  final double? progress;
  final String? meshyStatus;
  final String? meshyError;
  final String? thumbnailUrl;
  final String? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isTerminal =>
      status == MeshyJobStatus.completed || status == MeshyJobStatus.error;

  factory MeshyGenerationJob.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String?;
    final prompt = json['prompt'] as String?;
    final jobId = json['jobId'] as String?;
    if (statusName == null || prompt == null || jobId == null) {
      throw const MeshyProxyException(
        'The local Meshy proxy response was missing job metadata.',
      );
    }

    final status = MeshyJobStatus.values.byName(statusName);
    return MeshyGenerationJob(
      jobId: jobId,
      status: status,
      prompt: prompt,
      stage: json['stage'] as String?,
      previewTaskId: json['previewTaskId'] as String?,
      refineTaskId: json['refineTaskId'] as String?,
      glbUrl: json['glbUrl'] as String?,
      activeTaskId: json['activeTaskId'] as String?,
      progress: (json['progress'] as num?)?.toDouble(),
      meshyStatus: json['meshyStatus'] as String?,
      meshyError: json['meshyError'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      error: json['error'] as String?,
      createdAt: _tryParseDateTime(json['createdAt']),
      updatedAt: _tryParseDateTime(json['updatedAt']),
    );
  }

  static DateTime? _tryParseDateTime(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }

    return DateTime.tryParse(value)?.toUtc();
  }
}

class MeshyProxyException implements Exception {
  const MeshyProxyException(this.message);

  final String message;

  @override
  String toString() => 'MeshyProxyException: $message';
}
