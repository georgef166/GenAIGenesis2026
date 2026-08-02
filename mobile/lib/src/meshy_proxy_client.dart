import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Used when `MESHY_PROXY_BASE_URL` is not supplied via `--dart-define`.
///
/// This only resolves for emulator/desktop runs. A physical device must pass
/// the dev machine's LAN address explicitly.
const defaultProxyBaseUrl = 'http://localhost:8080';

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
        client: MeshyProxyClient(baseUri: Uri.parse(defaultProxyBaseUrl)),
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
            '$defaultProxyBaseUrl.',
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
      _httpClient =
          httpClient ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  // ponytail: JSON polls only. Asset downloads run through
  // `MeshyModelHistoryStore` and must never carry a wall-clock timeout — the
  // payloads this proxy streams are megabytes over a bridged LAN link.
  static const _requestTimeout = Duration(seconds: 20);

  final Uri _baseUri;
  final HttpClient _httpClient;

  Uri get baseUri => _baseUri;

  /// Releases the underlying connection pool. Safe to call more than once.
  void close() => _httpClient.close(force: true);

  /// [kind] is `'object'` or `'world'`. Both self-hosted models require
  /// [imageBytes]; [steps] only applies to worlds.
  Future<MeshyGenerationJob> createJob(
    String prompt, {
    String kind = 'object',
    Uint8List? imageBytes,
    int? steps,
  }) async {
    // ponytail: base64 in the JSON body, not multipart. This client writes to a
    // raw `dart:io` HttpRequest where multipart means hand-building boundaries;
    // the phone already downscales to well under the proxy's 8 MB cap, so the
    // ~33% wire overhead is cheaper than the code. Switch to a streamed
    // multipart POST here and at both proxy hops if photos ever grow.
    final response = await _sendJsonRequest(
      method: 'POST',
      pathSegments: const <String>['api', 'meshy', 'generate'],
      body: <String, Object?>{
        'prompt': prompt,
        'kind': kind,
        if (imageBytes != null) 'imageBase64': base64Encode(imageBytes),
        'steps': ?steps,
      },
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

    final HttpClientResponse response;
    try {
      response = await request.close().timeout(_requestTimeout);
    } on TimeoutException {
      throw const MeshyProxyException(
        'The local generation proxy did not respond in time.',
      );
    }

    final responseBody = await response.transform(utf8.decoder).join();
    // The status check comes first: an error body is often not JSON at all, and
    // decoding it first threw a raw FormatException past the error envelope.
    final decodedBody = _tryDecodeJson(responseBody);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw MeshyProxyException(
        _extractErrorMessage(decodedBody, response),
        statusCode: response.statusCode,
      );
    }

    if (decodedBody is! Map<String, dynamic>) {
      throw const MeshyProxyException(
        'The local generation proxy returned an unexpected JSON payload.',
      );
    }

    return decodedBody;
  }

  Object? _tryDecodeJson(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
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

    return 'The local generation proxy returned HTTP ${response.statusCode}.';
  }
}

/// Hand-mirrored from the proxy's `MeshyJobStatus`. Parsed by `.byName`, so a
/// value renamed on either side must be renamed on both — deliberately loud:
/// an unrecognised status throws rather than being silently tolerated.
enum MeshyJobStatus { submitting, previewing, refining, completed, error }

class MeshyGenerationJob {
  const MeshyGenerationJob({
    required this.jobId,
    required this.status,
    required this.prompt,
    this.kind,
    this.stage,
    this.previewTaskId,
    this.refineTaskId,
    this.glbUrl,
    this.panoramaUrl,
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

  /// `'object'` or `'world'`; absent on older proxies, which only made objects.
  final String? kind;
  final String? stage;
  final String? previewTaskId;
  final String? refineTaskId;
  final String? glbUrl;
  final String? panoramaUrl;
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
        'The local generation proxy response was missing job metadata.',
      );
    }

    final status = MeshyJobStatus.values.byName(statusName);
    return MeshyGenerationJob(
      jobId: jobId,
      status: status,
      prompt: prompt,
      kind: json['kind'] as String?,
      stage: json['stage'] as String?,
      previewTaskId: json['previewTaskId'] as String?,
      refineTaskId: json['refineTaskId'] as String?,
      glbUrl: json['glbUrl'] as String?,
      panoramaUrl: json['panoramaUrl'] as String?,
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
  const MeshyProxyException(this.message, {this.statusCode});

  final String message;

  /// The proxy's HTTP status, or `null` when the call never got a response at
  /// all. A poll retries on everything except a 404: that one means the proxy
  /// genuinely has no such job, so waiting cannot help.
  final int? statusCode;

  @override
  String toString() => 'MeshyProxyException: $message';
}
