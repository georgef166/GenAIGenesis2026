import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:genai_server/src/glb_repack.dart';
import 'package:shelf/shelf.dart';

class MeshyProxyApp {
  MeshyProxyApp({
    required MeshyApi meshyApi,
    MeshyApi? objectApi,
    Duration? pollInterval,
    Duration? stageTimeout,
    Duration? pollRetryBackoff,
    Duration? jobRetention,
  }) : _meshyApi = meshyApi,
       _objectApi = objectApi,
       _pollInterval = pollInterval ?? const Duration(seconds: 5),
       _stageTimeout = stageTimeout ?? const Duration(minutes: 12),
       _pollRetryBackoff = pollRetryBackoff ?? const Duration(seconds: 2),
       _jobRetention = jobRetention ?? const Duration(minutes: 30);

  /// Decoded size cap for an uploaded photo. The phone downscales before it
  /// uploads; anything past this is either a bug or an attack.
  static const _maxImageBytes = 8 * 1024 * 1024;

  /// Upper bound on an accepted prompt. The photo is already capped; without
  /// this a caller could still park megabytes of text per job in `_jobs`.
  static const _maxPromptLength = 1000;
  static const _minSteps = 10;
  static const _maxSteps = 60;

  /// The backend is reached over an SSH tunnel across a VPN and a generation
  /// runs for minutes, so a dropped read mid-job is expected. Tolerate a short
  /// blackout rather than throwing away GPU work that is still running.
  static const _maxPollFailures = 5;
  static const _maxPollRetryBackoff = Duration(seconds: 15);

  final MeshyApi _meshyApi;
  final MeshyApi? _objectApi;
  final Duration _pollInterval;
  final Duration _stageTimeout;
  final Duration _pollRetryBackoff;
  final Duration _jobRetention;
  final Map<String, MeshyJob> _jobs = <String, MeshyJob>{};
  final Map<String, Future<void>> _runningJobs = <String, Future<void>>{};
  final Random _random = Random.secure();

  // ponytail: autoUncompress off so upstream bytes (and the Content-Length we
  // forward) pass through verbatim. The backend never gzips binary assets; if
  // it ever does, forward Content-Encoding too.
  final HttpClient _assetClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = false;

  Handler get handler => (Request request) async {
    final pathSegments = request.url.pathSegments;

    if (request.method == 'GET' && request.url.path == 'healthz') {
      return _jsonResponse(HttpStatus.ok, <String, Object?>{'ok': true});
    }

    if (request.method == 'POST' &&
        pathSegments.length == 3 &&
        pathSegments[0] == 'api' &&
        pathSegments[1] == 'meshy' &&
        pathSegments[2] == 'generate') {
      return _createGenerationJob(request);
    }

    if (request.method == 'GET' &&
        pathSegments.length == 4 &&
        pathSegments[0] == 'api' &&
        pathSegments[1] == 'meshy' &&
        pathSegments[2] == 'generate') {
      return _getGenerationJob(request, pathSegments[3]);
    }

    if (request.method == 'GET' &&
        pathSegments.length == 5 &&
        pathSegments[0] == 'api' &&
        pathSegments[1] == 'meshy' &&
        pathSegments[2] == 'asset') {
      return _proxyAsset(pathSegments[3], pathSegments[4]);
    }

    return _jsonResponse(HttpStatus.notFound, <String, Object?>{
      'error': 'Route not found.',
    });
  };

  Future<void> waitForJob(String jobId) async {
    final future = _runningJobs[jobId];
    if (future != null) {
      await future;
    }
  }

  Future<Response> _createGenerationJob(Request request) async {
    Map<String, dynamic> payload;
    try {
      final rawBody = await request.readAsString();
      final decoded = rawBody.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(rawBody);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Request body must be a JSON object.');
      }
      payload = decoded;
    } on FormatException catch (error) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error': 'Invalid JSON body: ${error.message}',
      });
    }

    final prompt = (payload['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error': 'The "prompt" field must be a non-empty string.',
      });
    }
    if (prompt.length > _maxPromptLength) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error':
            'The "prompt" field must be at most $_maxPromptLength characters.',
      });
    }

    final rawKind = payload['kind'];
    final kind = rawKind == null
        ? 'object'
        : (rawKind is String ? rawKind.trim() : '');
    if (kind != 'object' && kind != 'world') {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error': 'The "kind" field must be either "object" or "world".',
      });
    }
    if (kind == 'object' && _objectApi == null) {
      return _jsonResponse(HttpStatus.serviceUnavailable, <String, Object?>{
        'error':
            'Object generation is not configured. Set '
            'GENAI_OBJECT_BACKEND_URL on the proxy.',
      });
    }

    final rawSteps = payload['steps'];
    if (rawSteps != null && rawSteps is! int) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error': 'The "steps" field must be an integer.',
      });
    }
    final steps = rawSteps == null
        ? null
        : min(_maxSteps, max(_minSteps, rawSteps));

    final rawImage = payload['imageBase64'];
    if (rawImage != null && rawImage is! String) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error': 'The "imageBase64" field must be a base64-encoded string.',
      });
    }
    final imageBase64 = (rawImage as String?)?.trim();
    final hasImage = imageBase64 != null && imageBase64.isNotEmpty;

    // Both self-hosted models are image-conditioned. The prompt steers HY-Pano
    // and remains the object model's history label.
    if (!hasImage) {
      return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
        'error':
            '${kind == 'world' ? 'World' : 'Object'} generation requires an '
            '"imageBase64" photo.',
      });
    }
    if (hasImage) {
      final rejection = _imageRejectionReason(imageBase64);
      if (rejection != null) {
        return _jsonResponse(HttpStatus.badRequest, <String, Object?>{
          'error': rejection,
        });
      }
    }

    _evictStaleJobs();

    final jobId = _nextJobId();
    final now = DateTime.now().toUtc();
    final job = MeshyJob(
      jobId: jobId,
      prompt: prompt,
      kind: kind,
      createdAt: now,
      updatedAt: now,
    );
    _jobs[jobId] = job;

    // The image is handed to the run, never stored on the job: `_jobs` lives
    // for the process lifetime and would pin megabytes per generation.
    final future = _runJob(jobId, imageBase64: imageBase64, steps: steps)
        .whenComplete(() {
          _runningJobs.remove(jobId);
        });
    _runningJobs[jobId] = future;
    unawaited(future);

    return _jsonResponse(HttpStatus.accepted, job.toJson());
  }

  /// Returns why [value] is unacceptable, or `null` when it is a base64 image
  /// within the cap. The decoded bytes are dropped immediately — only the
  /// base64 string travels on to the backend.
  String? _imageRejectionReason(String value) {
    // Base64 is 4 characters per 3 bytes, so the decoded size is known from the
    // string length alone and an oversized payload is never allocated at all.
    if (value.length ~/ 4 * 3 > _maxImageBytes) {
      return 'The "imageBase64" photo decodes to more than '
          '${_maxImageBytes ~/ (1024 * 1024)} MB. Downscale it before '
          'uploading.';
    }
    try {
      base64Decode(value);
    } on FormatException {
      return 'The "imageBase64" field is not valid base64.';
    }
    return null;
  }

  /// The phone can never reach the generation backend directly, so every asset
  /// URL handed out here is rewritten onto this proxy, using the host the
  /// caller actually dialled.
  Response _getGenerationJob(Request request, String jobId) {
    final job = _jobs[jobId];
    if (job == null) {
      return _jsonResponse(HttpStatus.notFound, <String, Object?>{
        'error': 'Generation job "$jobId" was not found.',
      });
    }

    final payload = job.toJson();
    if (job.glbUrl != null) {
      payload['glbUrl'] = _assetUrl(
        request,
        jobId,
        job.kind == 'world' ? 'sky.glb' : 'model.glb',
      );
    }
    if (job.panoramaUrl != null) {
      payload['panoramaUrl'] = _assetUrl(request, jobId, 'panorama.jpg');
    }
    return _jsonResponse(HttpStatus.ok, payload);
  }

  String _assetUrl(Request request, String jobId, String name) {
    return request.requestedUri
        .resolve('/api/meshy/asset/$jobId/$name')
        .toString();
  }

  Future<Response> _proxyAsset(String jobId, String name) async {
    final job = _jobs[jobId];
    final upstream = switch (name) {
      'model.glb' || 'sky.glb' => job?.glbUrl,
      'panorama.jpg' => job?.panoramaUrl,
      _ => null,
    };
    if (upstream == null || upstream.isEmpty) {
      return _jsonResponse(HttpStatus.notFound, <String, Object?>{
        'error': 'Asset "$name" is not available for job "$jobId".',
      });
    }

    final upstreamUri = Uri.parse(upstream);
    if (upstreamUri.scheme == 'file') {
      final file = File.fromUri(upstreamUri);
      if (!await file.exists()) {
        return _jsonResponse(HttpStatus.notFound, <String, Object?>{
          'error': 'Asset "$name" is no longer available for job "$jobId".',
        });
      }
      return Response.ok(
        file.openRead(),
        headers: <String, String>{
          HttpHeaders.contentTypeHeader: 'model/gltf-binary',
          HttpHeaders.contentLengthHeader: '${await file.length()}',
        },
      );
    }

    final HttpClientResponse upstreamResponse;
    try {
      final request = await _assetClient.getUrl(upstreamUri);
      upstreamResponse = await request.close();
    } catch (error) {
      return _jsonResponse(HttpStatus.badGateway, <String, Object?>{
        'error': 'Fetching "$name" from the generation backend failed: $error',
      });
    }

    if (upstreamResponse.statusCode >= HttpStatus.badRequest) {
      await upstreamResponse.drain<void>();
      return _jsonResponse(HttpStatus.badGateway, <String, Object?>{
        'error':
            'The generation backend returned HTTP '
            '${upstreamResponse.statusCode} for "$name".',
      });
    }

    final contentType = upstreamResponse.headers.contentType;
    final contentLength = upstreamResponse.contentLength;
    // An HttpClientResponse *is* a Stream<List<int>>, so shelf pipes it to the
    // phone without ever buffering the asset on this machine.
    return Response.ok(
      upstreamResponse,
      headers: <String, String>{
        if (contentType != null)
          HttpHeaders.contentTypeHeader: contentType.toString(),
        if (contentLength >= 0)
          HttpHeaders.contentLengthHeader: '$contentLength',
      },
    );
  }

  Future<void> _runJob(
    String jobId, {
    required String imageBase64,
    int? steps,
  }) async {
    try {
      final job = _requireJob(jobId);
      final api = job.kind == 'object' ? _objectApi! : _meshyApi;
      final task = await api.createTask(
        job.prompt,
        kind: job.kind,
        imageBase64: imageBase64,
        steps: job.kind == 'world' ? steps : null,
      );

      _updateJob(
        jobId,
        status: MeshyJobStatus.previewing,
        stage: 'preview',
        previewTaskId: task.taskId,
        activeTaskId: task.taskId,
        thumbnailUrl: task.thumbnailUrl,
      );

      final completedTask = await _pollTask(
        api,
        jobId,
        task.taskId,
        kind: job.kind,
      );

      final glbUrl = completedTask.glbUrl;
      if (glbUrl == null || glbUrl.isEmpty) {
        throw const MeshyTaskException(
          'The generation backend finished but did not return a GLB model URL.',
        );
      }

      _updateJob(
        jobId,
        status: MeshyJobStatus.completed,
        glbUrl: glbUrl,
        panoramaUrl: completedTask.panoramaUrl,
        activeTaskId: completedTask.id,
        meshyStatus: completedTask.status,
        progress: completedTask.progress,
        meshyError: completedTask.errorMessage,
        error: null,
      );
    } catch (error, stackTrace) {
      // The client only ever sees the normalized message now, so this is the
      // one place the real failure survives. Never drop the stack trace.
      stderr.writeln('[meshy] job=$jobId failed: $error');
      stderr.writeln(stackTrace);
      _updateJob(
        jobId,
        status: MeshyJobStatus.error,
        error: _normalizeErrorMessage(error),
      );
    }
  }

  Future<MeshyTask> _pollTask(
    MeshyApi api,
    String jobId,
    String taskId, {
    required String kind,
  }) async {
    // ponytail: worlds are minutes of diffusion, objects are not.
    final timeout = kind == 'world'
        ? const Duration(minutes: 20)
        : _stageTimeout;
    final deadline = DateTime.now().add(timeout);
    var consecutiveFailures = 0;
    DateTime? firstFailureAt;

    while (true) {
      final MeshyTask task;
      try {
        task = await api.getTask(taskId);
      } catch (error) {
        // A 404 means the backend genuinely lost the task, so there is nothing
        // to wait for. Everything else here is the tunnel dropping a read while
        // the GPU keeps working — retry instead of discarding the job.
        if (error is MeshyHttpException &&
            error.statusCode == HttpStatus.notFound) {
          rethrow;
        }

        consecutiveFailures++;
        firstFailureAt ??= DateTime.now();
        final blackout = DateTime.now().difference(firstFailureAt);
        if (consecutiveFailures >= _maxPollFailures ||
            DateTime.now().isAfter(deadline)) {
          throw MeshyTaskException(
            'Lost contact with the generation backend: $consecutiveFailures '
            'consecutive polls failed over ${blackout.inSeconds}s. '
            'Last failure: $error',
          );
        }

        final backoff = _pollRetryBackoff * (1 << (consecutiveFailures - 1));
        stdout.writeln(
          '[meshy] job=$jobId poll failed '
          '($consecutiveFailures/$_maxPollFailures), retrying: $error',
        );
        await Future<void>.delayed(
          backoff > _maxPollRetryBackoff ? _maxPollRetryBackoff : backoff,
        );
        continue;
      }

      consecutiveFailures = 0;
      firstFailureAt = null;
      final isTexturing = task.status.trim().toLowerCase() == 'texturing';
      _updateJob(
        jobId,
        status: isTexturing
            ? MeshyJobStatus.refining
            : MeshyJobStatus.previewing,
        stage: isTexturing ? 'texture' : 'preview',
        activeTaskId: task.id,
        meshyStatus: task.status,
        progress: task.progress,
        meshyError: task.errorMessage,
        // A poll without a thumbnail must not erase the one we already have.
        thumbnailUrl: task.thumbnailUrl ?? _unset,
      );
      if (task.isCompleted) {
        return task;
      }
      if (task.isFailed) {
        throw MeshyTaskException(
          task.errorMessage ??
              'The generation backend reported that the task failed.',
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        throw MeshyTaskException(
          'Generation timed out after ${timeout.inMinutes} minutes.',
        );
      }

      await Future<void>.delayed(_pollInterval);
    }
  }

  MeshyJob _requireJob(String jobId) {
    final job = _jobs[jobId];
    if (job == null) {
      throw StateError('Generation job "$jobId" does not exist.');
    }
    return job;
  }

  /// Every nullable field takes the [_unset] sentinel: passing a plain `null`
  /// default here forwarded an explicit `null` into [MeshyJob.copyWith] and
  /// cleared fields the caller never mentioned.
  void _updateJob(
    String jobId, {
    MeshyJobStatus? status,
    Object? stage = _unset,
    Object? previewTaskId = _unset,
    Object? glbUrl = _unset,
    Object? panoramaUrl = _unset,
    Object? activeTaskId = _unset,
    Object? meshyStatus = _unset,
    Object? progress = _unset,
    Object? meshyError = _unset,
    Object? thumbnailUrl = _unset,
    Object? error = _unset,
  }) {
    final current = _requireJob(jobId);
    final next = current.copyWith(
      status: status,
      stage: stage,
      previewTaskId: previewTaskId,
      glbUrl: glbUrl,
      panoramaUrl: panoramaUrl,
      activeTaskId: activeTaskId,
      meshyStatus: meshyStatus,
      progress: progress,
      meshyError: meshyError,
      thumbnailUrl: thumbnailUrl,
      error: error,
    );
    if (!_hasMeaningfulJobChange(current, next)) {
      return;
    }

    final stamped = next.copyWith(updatedAt: DateTime.now().toUtc());
    _jobs[jobId] = stamped;
    _logJobUpdate(current, stamped);
  }

  Response _jsonResponse(int statusCode, Map<String, Object?> body) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: const <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
    );
  }

  /// Drops finished jobs the app has had ample time to read back. `_jobs` is
  /// process-lifetime, so without this a long-running proxy keeps every job it
  /// ever ran — including the temp-file URI a completed object still points at.
  void _evictStaleJobs() {
    final cutoff = DateTime.now().toUtc().subtract(_jobRetention);
    _jobs.removeWhere(
      (jobId, job) =>
          job.isTerminal &&
          !_runningJobs.containsKey(jobId) &&
          job.updatedAt.isBefore(cutoff),
    );
  }

  String _nextJobId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final entropy = _random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
    return '$timestamp$entropy';
  }

  String _normalizeErrorMessage(Object error) {
    if (error is MeshyHttpException) {
      return error.message;
    }
    if (error is MeshyTaskException) {
      return error.message;
    }

    // Anything else — SocketException, HandshakeException, TimeoutException —
    // spells out the tunnel host and port the phone must never learn about.
    // The caller gets a generic message; `_runJob` logs the real one.
    return 'The proxy could not complete the generation request. '
        'Check the server logs for details.';
  }

  bool _hasMeaningfulJobChange(MeshyJob current, MeshyJob next) {
    return current.status != next.status ||
        current.stage != next.stage ||
        current.previewTaskId != next.previewTaskId ||
        current.glbUrl != next.glbUrl ||
        current.panoramaUrl != next.panoramaUrl ||
        current.activeTaskId != next.activeTaskId ||
        current.meshyStatus != next.meshyStatus ||
        current.progress != next.progress ||
        current.meshyError != next.meshyError ||
        current.thumbnailUrl != next.thumbnailUrl ||
        current.error != next.error;
  }

  void _logJobUpdate(MeshyJob previous, MeshyJob current) {
    final progressLabel = current.progress == null
        ? null
        : '${_formatProgress(current.progress!)}%';
    final fields = <String>[
      '[meshy]',
      'job=${current.jobId}',
      'status=${current.status.name}',
      if (current.stage != null) 'stage=${current.stage}',
      if (current.meshyStatus != null) 'meshy=${current.meshyStatus}',
      if (progressLabel != null) 'progress=$progressLabel',
      if (current.activeTaskId != null) 'task=${current.activeTaskId}',
      if (current.error != null && current.error != previous.error)
        'error=${current.error}',
    ];
    stdout.writeln(fields.join(' '));
  }

  String _formatProgress(double progress) {
    if (progress == progress.roundToDouble()) {
      return progress.toStringAsFixed(0);
    }
    return progress.toStringAsFixed(1);
  }
}

enum MeshyJobStatus { submitting, previewing, refining, completed, error }

class MeshyJob {
  const MeshyJob({
    required this.jobId,
    required this.prompt,
    required this.createdAt,
    required this.updatedAt,
    this.kind = 'object',
    this.status = MeshyJobStatus.submitting,
    this.stage,
    this.previewTaskId,
    this.glbUrl,
    this.panoramaUrl,
    this.activeTaskId,
    this.meshyStatus,
    this.progress,
    this.meshyError,
    this.thumbnailUrl,
    this.error,
  });

  final String jobId;
  final String prompt;

  /// `'object'` or `'world'`.
  final String kind;
  final DateTime createdAt;
  final DateTime updatedAt;
  final MeshyJobStatus status;
  final String? stage;
  final String? previewTaskId;
  final String? glbUrl;
  final String? panoramaUrl;
  final String? activeTaskId;
  final String? meshyStatus;
  final double? progress;
  final String? meshyError;
  final String? thumbnailUrl;
  final String? error;

  bool get isTerminal =>
      status == MeshyJobStatus.completed || status == MeshyJobStatus.error;

  MeshyJob copyWith({
    MeshyJobStatus? status,
    DateTime? updatedAt,
    Object? stage = _unset,
    Object? previewTaskId = _unset,
    Object? glbUrl = _unset,
    Object? panoramaUrl = _unset,
    Object? activeTaskId = _unset,
    Object? meshyStatus = _unset,
    Object? progress = _unset,
    Object? meshyError = _unset,
    Object? thumbnailUrl = _unset,
    Object? error = _unset,
  }) {
    return MeshyJob(
      jobId: jobId,
      prompt: prompt,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      stage: identical(stage, _unset) ? this.stage : stage as String?,
      previewTaskId: identical(previewTaskId, _unset)
          ? this.previewTaskId
          : previewTaskId as String?,
      glbUrl: identical(glbUrl, _unset) ? this.glbUrl : glbUrl as String?,
      panoramaUrl: identical(panoramaUrl, _unset)
          ? this.panoramaUrl
          : panoramaUrl as String?,
      activeTaskId: identical(activeTaskId, _unset)
          ? this.activeTaskId
          : activeTaskId as String?,
      meshyStatus: identical(meshyStatus, _unset)
          ? this.meshyStatus
          : meshyStatus as String?,
      progress: identical(progress, _unset)
          ? this.progress
          : progress as double?,
      meshyError: identical(meshyError, _unset)
          ? this.meshyError
          : meshyError as String?,
      thumbnailUrl: identical(thumbnailUrl, _unset)
          ? this.thumbnailUrl
          : thumbnailUrl as String?,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'jobId': jobId,
      'status': status.name,
      'prompt': prompt,
      'kind': kind,
      'stage': stage,
      'previewTaskId': previewTaskId,
      // ponytail: kept on the wire, permanently null, so the shipped client
      // parser stays untouched. There is no second stage any more.
      'refineTaskId': null,
      'glbUrl': glbUrl,
      'panoramaUrl': panoramaUrl,
      'activeTaskId': activeTaskId,
      'meshyStatus': meshyStatus,
      'progress': progress,
      'meshyError': meshyError,
      'thumbnailUrl': thumbnailUrl,
      'error': error,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}

// ponytail: the `Meshy*` prefix is historical. Meshy is gone; these names now
// mean "the generation backend" and stay only because the enum values are
// hand-mirrored in the shipped app and parsed by `.byName`.
abstract interface class MeshyApi {
  /// [kind] is `'object'` or `'world'`. Both backends require [imageBase64];
  /// only the panorama backend accepts [steps].
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  });

  Future<MeshyTask> getTask(String taskId);
}

/// Talks to the self-hosted generation service on the A100 box, reached over an
/// SSH tunnel. No credentials: the tunnel is the authentication.
class TencentHttpApi implements MeshyApi {
  TencentHttpApi({required Uri baseUri, HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient(),
      _baseUri = baseUri {
    _httpClient.connectionTimeout = const Duration(seconds: 10);
  }

  static const _requestTimeout = Duration(seconds: 30);

  final HttpClient _httpClient;
  final Uri _baseUri;

  @override
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  }) async {
    // ponytail: base64 inside the JSON body rather than multipart. This class
    // writes to a raw `dart:io` HttpRequest, where multipart means hand-rolling
    // boundaries and Content-Disposition headers on all three hops. The cost is
    // ~33% wire overhead and the whole body in memory; if photos ever get large
    // enough to matter, switch this call (and the two hops either side) to a
    // streamed multipart POST.
    final jsonBody = await _requestJson(
      'POST',
      '/generate',
      body: <String, Object?>{
        'prompt': prompt,
        'kind': kind,
        'image_b64': ?imageBase64,
        'steps': ?steps,
      },
    );
    return MeshyCreatedTask.fromJson(jsonBody);
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    final jsonBody = await _requestJson('GET', '/task/$taskId');
    return MeshyTask.fromJson(jsonBody, id: taskId);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = _baseUri.resolve(path);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
    }

    final response = await request.close().timeout(_requestTimeout);
    final responseBody = await response.transform(utf8.decoder).join();
    final jsonBody = responseBody.isEmpty ? null : jsonDecode(responseBody);

    if (response.statusCode >= HttpStatus.badRequest) {
      throw MeshyHttpException(
        statusCode: response.statusCode,
        message:
            _extractApiErrorMessage(jsonBody) ??
            'The generation backend failed with HTTP ${response.statusCode}.',
      );
    }

    if (jsonBody is! Map<String, dynamic>) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.internalServerError,
        message: 'The generation backend returned an unexpected payload.',
      );
    }

    return jsonBody;
  }

  String? _extractApiErrorMessage(Object? body) {
    if (body is Map<String, dynamic>) {
      for (final key in const <String>['error', 'message', 'detail']) {
        final value = body[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }

    return null;
  }
}

/// Adapts Hunyuan3D-2.1's image-to-3D API to the shared job shape.
class Hunyuan3dHttpApi extends TencentHttpApi {
  Hunyuan3dHttpApi({
    required super.baseUri,
    super.httpClient,
    Directory? assetDirectory,
  }) : _assetDirectory =
           // ponytail: jobs already live for the proxy lifetime; use OS temp
           // beside them. Add retention cleanup only if jobs become persistent.
           assetDirectory ??
           Directory('${Directory.systemTemp.path}/genai-hunyuan3d-assets') {
    _assetDirectory.createSync(recursive: true);
  }

  static final _taskIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final Directory _assetDirectory;

  @override
  Future<MeshyCreatedTask> createTask(
    String prompt, {
    required String kind,
    String? imageBase64,
    int? steps,
  }) async {
    if (imageBase64 == null || imageBase64.isEmpty) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.badRequest,
        message: 'Hunyuan3D requires an input image.',
      );
    }

    final response = await _requestJson(
      'POST',
      '/send',
      body: <String, Object?>{
        'image': imageBase64,
        'remove_background': true,
        'texture': true,
      },
    );
    final taskId = response['uid'];
    if (taskId is! String || !_taskIdPattern.hasMatch(taskId)) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.badGateway,
        message: 'Hunyuan3D returned an invalid task id.',
      );
    }
    return MeshyCreatedTask(taskId: taskId);
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    if (!_taskIdPattern.hasMatch(taskId)) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.badRequest,
        message: 'Hunyuan3D task id is invalid.',
      );
    }

    final response = await _requestJson('GET', '/status/$taskId');
    final status = (response['status'] as String?)?.trim().toLowerCase();
    switch (status) {
      case 'processing':
        return MeshyTask(id: taskId, status: status!, progress: 25);
      case 'texturing':
        return MeshyTask(id: taskId, status: status!, progress: 70);
      case 'error':
        return MeshyTask(
          id: taskId,
          status: status!,
          errorMessage: MeshyTask._trimmedOrNull(response['message']),
        );
      case 'completed':
        final encoded = response['model_base64'];
        if (encoded is! String || encoded.isEmpty) {
          throw const MeshyHttpException(
            statusCode: HttpStatus.badGateway,
            message: 'Hunyuan3D completed without returning model_base64.',
          );
        }

        final Uint8List bytes;
        try {
          bytes = base64Decode(encoded);
        } on FormatException {
          throw const MeshyHttpException(
            statusCode: HttpStatus.badGateway,
            message: 'Hunyuan3D returned invalid model_base64.',
          );
        }
        final declaredLength = bytes.length < 12
            ? -1
            : ByteData.sublistView(bytes).getUint32(8, Endian.little);
        if (bytes.length < 12 ||
            bytes[0] != 0x67 ||
            bytes[1] != 0x6c ||
            bytes[2] != 0x54 ||
            bytes[3] != 0x46 ||
            declaredLength != bytes.length) {
          throw const MeshyHttpException(
            statusCode: HttpStatus.badGateway,
            message: 'Hunyuan3D returned an invalid GLB.',
          );
        }

        // Hunyuan3D embeds its textures as `data:` URIs and mislabels JPEG as
        // PNG; Android's loader refuses both. Repack once, here, so the phone
        // only ever sees a spec-correct GLB.
        final file = File('${_assetDirectory.path}/$taskId.glb');
        await file.writeAsBytes(repackGlbDataUriImages(bytes), flush: true);
        return MeshyTask(
          id: taskId,
          status: status!,
          progress: 100,
          glbUrl: file.uri.toString(),
        );
      default:
        throw MeshyHttpException(
          statusCode: HttpStatus.badGateway,
          message: 'Hunyuan3D returned unknown status "${response['status']}".',
        );
    }
  }
}

class MeshyCreatedTask {
  const MeshyCreatedTask({required this.taskId, this.thumbnailUrl});

  final String taskId;
  final String? thumbnailUrl;

  factory MeshyCreatedTask.fromJson(Map<String, dynamic> json) {
    final taskId = json['task_id'];
    if (taskId is String && taskId.trim().isNotEmpty) {
      return MeshyCreatedTask(
        taskId: taskId.trim(),
        thumbnailUrl: json['thumbnail_url'] as String?,
      );
    }

    throw MeshyHttpException(
      statusCode: HttpStatus.internalServerError,
      message:
          'The generation backend create response was missing the required '
          '"task_id". Received: ${jsonEncode(json)}',
    );
  }
}

class MeshyTask {
  const MeshyTask({
    required this.id,
    required this.status,
    this.progress,
    this.thumbnailUrl,
    this.glbUrl,
    this.panoramaUrl,
    this.errorMessage,
  });

  final String id;
  final String status;
  final double? progress;
  final String? thumbnailUrl;
  final String? glbUrl;
  final String? panoramaUrl;
  final String? errorMessage;

  bool get isCompleted =>
      _normalizedStatus == 'succeeded' || _normalizedStatus == 'completed';
  bool get isFailed => const <String>{
    'failed',
    'error',
    'cancelled',
    'canceled',
    'expired',
  }.contains(_normalizedStatus);

  String get _normalizedStatus => status.trim().toLowerCase();

  /// The backend echoes no task id, so the caller supplies the [id] it polled.
  factory MeshyTask.fromJson(Map<String, dynamic> json, {required String id}) {
    final status = json['status'];
    if (status is! String || status.trim().isEmpty) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.internalServerError,
        message: 'The generation backend task response had no "status".',
      );
    }

    final progress = json['progress'];
    return MeshyTask(
      id: id,
      status: status,
      progress: progress is num ? progress.toDouble() : null,
      glbUrl: _trimmedOrNull(json['glb_url']),
      panoramaUrl: _trimmedOrNull(json['panorama_url']),
      errorMessage: _trimmedOrNull(json['error']),
    );
  }

  static String? _trimmedOrNull(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}

class MeshyHttpException implements Exception {
  const MeshyHttpException({required this.statusCode, required this.message});

  final int statusCode;
  final String message;

  @override
  String toString() => 'MeshyHttpException($statusCode): $message';
}

class MeshyTaskException implements Exception {
  const MeshyTaskException(this.message);

  final String message;

  @override
  String toString() => 'MeshyTaskException: $message';
}

const Object _unset = Object();
