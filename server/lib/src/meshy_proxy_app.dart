import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';

class MeshyProxyApp {
  MeshyProxyApp({
    required MeshyApi meshyApi,
    Duration? pollInterval,
    Duration? stageTimeout,
  }) : _meshyApi = meshyApi,
       _pollInterval = pollInterval ?? const Duration(seconds: 5),
       _stageTimeout = stageTimeout ?? const Duration(minutes: 12);

  final MeshyApi _meshyApi;
  final Duration _pollInterval;
  final Duration _stageTimeout;
  final Map<String, MeshyJob> _jobs = <String, MeshyJob>{};
  final Map<String, Future<void>> _runningJobs = <String, Future<void>>{};
  final Random _random = Random.secure();

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
      return _getGenerationJob(pathSegments[3]);
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

    final jobId = _nextJobId();
    final now = DateTime.now().toUtc();
    final job = MeshyJob(
      jobId: jobId,
      prompt: prompt,
      createdAt: now,
      updatedAt: now,
    );
    _jobs[jobId] = job;

    final future = _runJob(jobId).whenComplete(() {
      _runningJobs.remove(jobId);
    });
    _runningJobs[jobId] = future;
    unawaited(future);

    return _jsonResponse(HttpStatus.accepted, job.toJson());
  }

  Response _getGenerationJob(String jobId) {
    final job = _jobs[jobId];
    if (job == null) {
      return _jsonResponse(HttpStatus.notFound, <String, Object?>{
        'error': 'Generation job "$jobId" was not found.',
      });
    }

    return _jsonResponse(HttpStatus.ok, job.toJson());
  }

  Future<void> _runJob(String jobId) async {
    try {
      final job = _requireJob(jobId);
      final previewTask = await _meshyApi.createPreviewTask(job.prompt);

      _updateJob(
        jobId,
        status: MeshyJobStatus.previewing,
        stage: 'preview',
        previewTaskId: previewTask.taskId,
        activeTaskId: previewTask.taskId,
        thumbnailUrl: previewTask.thumbnailUrl,
      );

      final completedPreviewTask = await _pollTask(
        jobId,
        previewTask.taskId,
        stageLabel: 'preview',
      );

      final refineTask = await _meshyApi.createRefineTask(
        previewTaskId: completedPreviewTask.id,
        prompt: job.prompt,
      );

      _updateJob(
        jobId,
        status: MeshyJobStatus.refining,
        stage: 'refine',
        previewTaskId: completedPreviewTask.id,
        refineTaskId: refineTask.taskId,
        activeTaskId: refineTask.taskId,
        thumbnailUrl:
            completedPreviewTask.thumbnailUrl ?? refineTask.thumbnailUrl,
      );

      final completedRefineTask = await _pollTask(
        jobId,
        refineTask.taskId,
        stageLabel: 'refine',
      );

      final glbUrl = completedRefineTask.glbUrl;
      if (glbUrl == null || glbUrl.isEmpty) {
        throw MeshyTaskException(
          'Meshy completed the refine task but did not return a GLB model URL.',
        );
      }

      _updateJob(
        jobId,
        status: MeshyJobStatus.completed,
        stage: 'refine',
        previewTaskId: completedPreviewTask.id,
        refineTaskId: completedRefineTask.id,
        glbUrl: glbUrl,
        activeTaskId: completedRefineTask.id,
        meshyStatus: completedRefineTask.status,
        progress: completedRefineTask.progress,
        meshyError: completedRefineTask.errorMessage,
        thumbnailUrl:
            completedRefineTask.thumbnailUrl ??
            completedPreviewTask.thumbnailUrl,
        error: null,
      );
    } catch (error) {
      _updateJob(
        jobId,
        status: MeshyJobStatus.error,
        error: _normalizeErrorMessage(error),
      );
    }
  }

  Future<MeshyTask> _pollTask(
    String jobId,
    String taskId, {
    required String stageLabel,
  }) async {
    final deadline = DateTime.now().add(_stageTimeout);

    while (true) {
      final task = await _meshyApi.getTask(taskId);
      _updateJob(
        jobId,
        status: stageLabel == 'preview'
            ? MeshyJobStatus.previewing
            : MeshyJobStatus.refining,
        stage: stageLabel,
        activeTaskId: task.id,
        meshyStatus: task.status,
        progress: task.progress,
        meshyError: task.errorMessage,
        thumbnailUrl: task.thumbnailUrl,
      );
      if (task.isCompleted) {
        return task;
      }
      if (task.isFailed) {
        throw MeshyTaskException(
          task.errorMessage ??
              'Meshy reported that the $stageLabel task failed.',
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        throw MeshyTaskException(
          'Meshy $stageLabel generation timed out after '
          '${_stageTimeout.inMinutes} minutes.',
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

  void _updateJob(
    String jobId, {
    MeshyJobStatus? status,
    String? stage,
    String? previewTaskId,
    String? refineTaskId,
    String? glbUrl,
    String? activeTaskId,
    String? meshyStatus,
    double? progress,
    String? meshyError,
    String? thumbnailUrl,
    String? error,
  }) {
    final current = _requireJob(jobId);
    final next = current.copyWith(
      status: status,
      stage: stage,
      previewTaskId: previewTaskId,
      refineTaskId: refineTaskId,
      glbUrl: glbUrl,
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
    return error.toString();
  }

  bool _hasMeaningfulJobChange(MeshyJob current, MeshyJob next) {
    return current.status != next.status ||
        current.stage != next.stage ||
        current.previewTaskId != next.previewTaskId ||
        current.refineTaskId != next.refineTaskId ||
        current.glbUrl != next.glbUrl ||
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
    this.status = MeshyJobStatus.submitting,
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
  });

  final String jobId;
  final String prompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final MeshyJobStatus status;
  final String? stage;
  final String? previewTaskId;
  final String? refineTaskId;
  final String? glbUrl;
  final String? activeTaskId;
  final String? meshyStatus;
  final double? progress;
  final String? meshyError;
  final String? thumbnailUrl;
  final String? error;

  MeshyJob copyWith({
    MeshyJobStatus? status,
    DateTime? updatedAt,
    Object? stage = _unset,
    Object? previewTaskId = _unset,
    Object? refineTaskId = _unset,
    Object? glbUrl = _unset,
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
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      stage: identical(stage, _unset) ? this.stage : stage as String?,
      previewTaskId: identical(previewTaskId, _unset)
          ? this.previewTaskId
          : previewTaskId as String?,
      refineTaskId: identical(refineTaskId, _unset)
          ? this.refineTaskId
          : refineTaskId as String?,
      glbUrl: identical(glbUrl, _unset) ? this.glbUrl : glbUrl as String?,
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
      'stage': stage,
      'previewTaskId': previewTaskId,
      'refineTaskId': refineTaskId,
      'glbUrl': glbUrl,
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

abstract interface class MeshyApi {
  Future<MeshyCreatedTask> createPreviewTask(String prompt);

  Future<MeshyCreatedTask> createRefineTask({
    required String previewTaskId,
    required String prompt,
  });

  Future<MeshyTask> getTask(String taskId);
}

class MeshyHttpApi implements MeshyApi {
  MeshyHttpApi({required String apiKey, HttpClient? httpClient, Uri? baseUri})
    : _apiKey = apiKey,
      _httpClient = httpClient ?? HttpClient(),
      _baseUri = baseUri ?? Uri.parse('https://api.meshy.ai');

  final String _apiKey;
  final HttpClient _httpClient;
  final Uri _baseUri;

  @override
  Future<MeshyCreatedTask> createPreviewTask(String prompt) async {
    return _requestCreatedTask(
      'POST',
      '/openapi/v2/text-to-3d',
      body: <String, Object?>{
        'mode': 'preview',
        'prompt': prompt,
        'ai_model': 'latest',
        'art_style': 'realistic',
        'should_remesh': true,
        'moderation': true,
      },
    );
  }

  @override
  Future<MeshyCreatedTask> createRefineTask({
    required String previewTaskId,
    required String prompt,
  }) async {
    return _requestCreatedTask(
      'POST',
      '/openapi/v2/text-to-3d',
      body: <String, Object?>{
        'mode': 'refine',
        'preview_task_id': previewTaskId,
        'ai_model': 'latest',
        'enable_pbr': true,
        'remove_lighting': true,
        'texture_prompt': prompt,
        'moderation': true,
      },
    );
  }

  @override
  Future<MeshyTask> getTask(String taskId) async {
    return _requestTask('GET', '/openapi/v2/text-to-3d/$taskId');
  }

  Future<MeshyCreatedTask> _requestCreatedTask(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final jsonBody = await _requestJson(method, path, body: body);
    return MeshyCreatedTask.fromJson(jsonBody);
  }

  Future<MeshyTask> _requestTask(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final jsonBody = await _requestJson(method, path, body: body);
    return MeshyTask.fromJson(jsonBody);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = _baseUri.resolve(path);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
    }

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    final jsonBody = responseBody.isEmpty ? null : jsonDecode(responseBody);

    if (response.statusCode >= HttpStatus.badRequest) {
      throw MeshyHttpException(
        statusCode: response.statusCode,
        message:
            _extractApiErrorMessage(jsonBody) ??
            'Meshy request failed with HTTP ${response.statusCode}.',
      );
    }

    if (jsonBody is! Map<String, dynamic>) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.internalServerError,
        message: 'Meshy returned an unexpected response payload.',
      );
    }

    return jsonBody;
  }

  String? _extractApiErrorMessage(Object? body) {
    if (body is Map<String, dynamic>) {
      final directMessage = body['message'];
      if (directMessage is String && directMessage.trim().isNotEmpty) {
        return directMessage.trim();
      }

      final error = body['error'];
      if (error is Map<String, dynamic>) {
        final nestedMessage = error['message'];
        if (nestedMessage is String && nestedMessage.trim().isNotEmpty) {
          return nestedMessage.trim();
        }
      }
    }

    return null;
  }
}

class MeshyCreatedTask {
  const MeshyCreatedTask({required this.taskId, this.thumbnailUrl});

  final String taskId;
  final String? thumbnailUrl;

  factory MeshyCreatedTask.fromJson(Map<String, dynamic> json) {
    final result = json['result'];
    if (result is String && result.trim().isNotEmpty) {
      return MeshyCreatedTask(
        taskId: result.trim(),
        thumbnailUrl: json['thumbnail_url'] as String?,
      );
    }

    throw MeshyHttpException(
      statusCode: HttpStatus.internalServerError,
      message:
          'Meshy create response was missing the required "result" task ID. '
          'Received: ${jsonEncode(json)}',
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
    this.errorMessage,
  });

  final String id;
  final String status;
  final double? progress;
  final String? thumbnailUrl;
  final String? glbUrl;
  final String? errorMessage;

  bool get isCompleted => _normalizedStatus == 'succeeded';
  bool get isFailed => const <String>{
    'failed',
    'cancelled',
    'canceled',
    'expired',
  }.contains(_normalizedStatus);

  String get _normalizedStatus => status.trim().toLowerCase();

  factory MeshyTask.fromJson(Map<String, dynamic> json) {
    final modelUrls = json['model_urls'];
    final taskError = json['task_error'];

    String? errorMessage;
    if (taskError is Map<String, dynamic>) {
      final message = taskError['message'];
      if (message is String && message.trim().isNotEmpty) {
        errorMessage = message.trim();
      }
    } else if (taskError is String && taskError.trim().isNotEmpty) {
      errorMessage = taskError.trim();
    }

    String? glbUrl;
    if (modelUrls is Map<String, dynamic>) {
      final candidate = modelUrls['glb'];
      if (candidate is String && candidate.trim().isNotEmpty) {
        glbUrl = candidate.trim();
      }
    }

    final thumbnailUrl = json['thumbnail_url'] as String?;
    final progressValue = json['progress'];
    final progress = progressValue is num ? progressValue.toDouble() : null;
    final id = json['id'] as String?;
    final status = json['status'] as String?;
    if (id == null || status == null) {
      throw const MeshyHttpException(
        statusCode: HttpStatus.internalServerError,
        message: 'Meshy response was missing required task fields.',
      );
    }

    return MeshyTask(
      id: id,
      status: status,
      progress: progress,
      thumbnailUrl: thumbnailUrl,
      glbUrl: glbUrl,
      errorMessage: errorMessage,
    );
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
