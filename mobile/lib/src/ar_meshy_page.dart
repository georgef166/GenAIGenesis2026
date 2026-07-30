import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'meshy_model_history.dart';
import 'meshy_proxy_client.dart';

const _backgroundColor = Color(0xFF02040a);

const _jobPollInterval = Duration(seconds: 3);

/// A generation runs for minutes and the proxy keeps tracking it, so a dropped
/// poll must not abandon the job. Retry a bounded run before giving up.
const _maxPollFailures = 5;
const _maxPollRetryBackoff = Duration(seconds: 15);

const _generatedModelScale = 0.14;

/// The vendored plugin's iOS side scales every GLTF child by 0.01, so every
/// `localGLTF2`/`webGLB` node has to undo it. Mirrors `ar_rocket_page.dart:32`.
const _iosPluginModelScaleCompensation = 100.0;

/// The proxy caps an upload at 8 MB decoded and a modern phone photo is 4–12 MB
/// straight off the sensor, so the picker resamples before we ever see bytes.
const _uploadMaxEdge = 1536.0;
const _uploadJpegQuality = 85;

enum ARSessionState {
  checkingPermission,
  permissionRequired,
  permissionBlocked,
  checkingSupport,
  initializing,
  scanning,
  readyToPlace,
  placing,
  placed,
  unsupported,
  error,
}

enum MeshyGenerationStage {
  idle,
  missingProxyConfig,
  submitting,
  previewing,
  refining,
  ready,
  error,
}

class ARMeshyPage extends StatefulWidget {
  const ARMeshyPage({super.key});

  @override
  State<ARMeshyPage> createState() => _ARMeshyPageState();
}

class _ARMeshyPageState extends State<ARMeshyPage> with WidgetsBindingObserver {
  final TextEditingController _promptController = TextEditingController();
  late final MeshyProxyConfiguration _proxyConfiguration =
      MeshyProxyConfiguration.fromEnvironment();
  late final MeshyModelHistoryStore _modelHistoryStore =
      MeshyModelHistoryStore();
  late final MeshyPlacementRuntime _placementRuntime =
      detectMeshyPlacementRuntime();
  final ImagePicker _imagePicker = ImagePicker();
  final List<MeshyModelRecord> _recentModels = <MeshyModelRecord>[];

  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;

  ARPlaneAnchor? _modelAnchor;
  ARNode? _modelNode;

  ARSessionState _sessionState = ARSessionState.checkingPermission;
  MeshyGenerationStage _generationStage = MeshyGenerationStage.idle;
  String? _sessionErrorMessage;
  String? _generationErrorMessage;
  MeshyGenerationJob? _currentJob;
  MeshyActiveModel? _activeModel;
  String _generationKind = 'object';
  Uint8List? _generationImageBytes;
  int _worldSteps = 12;
  String? _panoramaUrl;
  bool _isCameraPermissionGranted = false;
  bool _hasHorizontalPlane = false;
  bool _hasInitializedSession = false;
  bool _isConfiguringSession = false;
  bool _isLoadingHistory = true;
  int _planeCount = 0;
  int _generationToken = 0;
  int _pollRetryAttempt = 0;

  MeshyProxyClient? get _meshyClient => _proxyConfiguration.client;

  bool get _isWorldMode => _generationKind == 'world';

  bool get _isGenerating =>
      _generationStage == MeshyGenerationStage.submitting ||
      _generationStage == MeshyGenerationStage.previewing ||
      _generationStage == MeshyGenerationStage.refining;

  bool get _hasGeneratedModel => _activeModel != null;

  String? get _currentJobId => _currentJob?.jobId;

  String? get _currentMeshyStageLabel {
    switch (_currentJob?.stage) {
      case 'preview':
        return 'Preview';
      case 'refine':
        return 'Refine';
      default:
        return null;
    }
  }

  String? get _currentMeshyTaskId =>
      _currentJob?.activeTaskId ??
      _currentJob?.refineTaskId ??
      _currentJob?.previewTaskId;

  String? get _currentProgressLabel {
    final progress = _currentJob?.progress;
    if (progress == null) {
      return null;
    }

    if (progress == progress.roundToDouble()) {
      return '${progress.toStringAsFixed(0)}%';
    }
    return '${progress.toStringAsFixed(1)}%';
  }

  bool get _isProgressUpdateStale {
    final updatedAt = _currentJob?.updatedAt;
    if (updatedAt == null) {
      return false;
    }

    return DateTime.now().toUtc().difference(updatedAt).inSeconds >= 20;
  }

  String get _statusTitle {
    switch (_sessionState) {
      case ARSessionState.checkingPermission:
        return 'Checking camera';
      case ARSessionState.permissionRequired:
        return 'Camera required';
      case ARSessionState.permissionBlocked:
        return 'Camera blocked';
      case ARSessionState.checkingSupport:
        return 'Opening AR view';
      case ARSessionState.initializing:
        return 'Initializing AR';
      case ARSessionState.unsupported:
        return 'AR unsupported';
      case ARSessionState.error:
        return 'AR error';
      case ARSessionState.placing:
        return 'Placing model';
      case ARSessionState.placed:
        return 'Model anchored';
      case ARSessionState.scanning:
      case ARSessionState.readyToPlace:
        break;
    }

    switch (_generationStage) {
      case MeshyGenerationStage.missingProxyConfig:
        if (_recentModels.isNotEmpty) {
          return 'Load a recent model';
        }
        return 'Server config required';
      case MeshyGenerationStage.submitting:
        return 'Submitting prompt';
      case MeshyGenerationStage.previewing:
        return 'Generating preview';
      case MeshyGenerationStage.refining:
        return 'Refining model';
      case MeshyGenerationStage.error:
        return 'Generation failed';
      case MeshyGenerationStage.ready:
        return _hasHorizontalPlane ? 'Tap to place' : 'Scan surfaces';
      case MeshyGenerationStage.idle:
        return 'Generate a model';
    }
  }

  String get _statusMessage {
    switch (_sessionState) {
      case ARSessionState.checkingPermission:
        return 'Checking camera permission...';
      case ARSessionState.permissionRequired:
        return 'Camera access is required before the AR session can start.';
      case ARSessionState.permissionBlocked:
        return 'Camera access is blocked. Open settings to allow the app to '
            'use AR.';
      case ARSessionState.checkingSupport:
        return 'Opening the AR camera...';
      case ARSessionState.initializing:
        return 'Initializing the AR session...';
      case ARSessionState.unsupported:
      case ARSessionState.error:
        return _sessionErrorMessage ?? 'The AR session could not start.';
      case ARSessionState.placing:
        return 'Anchoring the generated model to the detected plane...';
      case ARSessionState.placed:
        return 'Model placed. Reset to place it again or generate a new prompt.';
      case ARSessionState.scanning:
      case ARSessionState.readyToPlace:
        break;
    }

    if (_pollRetryAttempt > 0) {
      return 'Lost contact with the server — retrying '
          '($_pollRetryAttempt of $_maxPollFailures). The generation is still '
          'running on the server.';
    }

    switch (_generationStage) {
      case MeshyGenerationStage.missingProxyConfig:
        if (_recentModels.isNotEmpty) {
          return 'Recent models are available below. Configure the proxy only '
              'if you want to generate a new one.';
        }
        return _proxyConfiguration.error ??
            'The app is missing the generation proxy base URL.';
      case MeshyGenerationStage.submitting:
        return 'Sending your photo to the local generation proxy...';
      case MeshyGenerationStage.previewing:
        return _buildProgressStatusMessage(
          stageFallback: 'The generation backend is creating your model.',
        );
      case MeshyGenerationStage.refining:
        return _buildProgressStatusMessage(
          stageFallback: 'The generation backend is texturing the GLB model.',
        );
      case MeshyGenerationStage.error:
        return _generationErrorMessage ??
            'The backend could not generate a model.';
      case MeshyGenerationStage.ready:
        return _hasHorizontalPlane
            ? 'Tap a horizontal surface to place the selected model.'
            : 'Model ready. Move your phone slowly to detect a flat surface.';
      case MeshyGenerationStage.idle:
        if (_recentModels.isNotEmpty) {
          return _hasHorizontalPlane
              ? 'Enter a prompt or load a recent model, then tap to place it.'
              : 'Enter a prompt or load a recent model, and move your phone '
                    'slowly to detect a flat surface.';
        }
        return _hasHorizontalPlane
            ? 'Enter a prompt, generate a model, then tap to place it.'
            : 'Enter a prompt, generate a model, and move your phone slowly '
                  'to detect a flat surface.';
    }
  }

  String get _promptHelperText {
    final currentJobSuffix = _currentJobId == null
        ? ''
        : ' Job $_currentJobId is active.';

    switch (_generationStage) {
      case MeshyGenerationStage.missingProxyConfig:
        if (_recentModels.isNotEmpty) {
          return 'Recent models remain available below. '
              'Set MESHY_PROXY_BASE_URL to generate new ones.';
        }
        return _proxyConfiguration.error ??
            'Set MESHY_PROXY_BASE_URL before running the app.';
      case MeshyGenerationStage.submitting:
        return 'Prompt accepted. Waiting for the preview task to start.'
            '$currentJobSuffix';
      case MeshyGenerationStage.previewing:
        return _buildProgressHelperText(
          fallback:
              'The generation task is running on the local proxy.'
              '$currentJobSuffix',
        );
      case MeshyGenerationStage.refining:
        return _buildProgressHelperText(
          fallback:
              'Shape complete. The backend is texturing the model now.'
              '$currentJobSuffix',
        );
      case MeshyGenerationStage.ready:
        return _activeModel?.isPersisted == true
            ? 'Saved model ready. Tap a plane to place it.'
            : 'Generated model ready. Tap a plane to place it.';
      case MeshyGenerationStage.error:
        return _generationErrorMessage ?? 'Generation failed.';
      case MeshyGenerationStage.idle:
        return 'Run the proxy on your computer at http://nixos:8080. '
            'Use --dart-define=MESHY_PROXY_BASE_URL=http://<LAN-IP>:8080 '
            'to override it.';
    }
  }

  String? get _primaryActionLabel {
    switch (_sessionState) {
      case ARSessionState.permissionRequired:
        return 'Grant camera access';
      case ARSessionState.permissionBlocked:
        return 'Open settings';
      case ARSessionState.checkingPermission:
      case ARSessionState.checkingSupport:
      case ARSessionState.initializing:
      case ARSessionState.scanning:
      case ARSessionState.readyToPlace:
      case ARSessionState.placing:
      case ARSessionState.placed:
      case ARSessionState.unsupported:
      case ARSessionState.error:
        return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _promptController.addListener(_handlePromptChanged);
    _generationStage = _meshyClient == null
        ? MeshyGenerationStage.missingProxyConfig
        : MeshyGenerationStage.idle;
    _generationErrorMessage = _proxyConfiguration.error;
    _loadRecentModels();
    _ensureCameraPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureCameraPermission(requestIfNeeded: false);
    }
  }

  void _handlePromptChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  Future<void> _loadRecentModels() async {
    try {
      final records = await _modelHistoryStore.loadRecords();
      if (!mounted) {
        return;
      }

      setState(() {
        _recentModels
          ..clear()
          ..addAll(records);
        _isLoadingHistory = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoadingHistory = false;
      });
      _showTransientMessage('Failed to load saved generated models: $error');
    }
  }

  Future<void> _ensureCameraPermission({bool requestIfNeeded = true}) async {
    _setSessionState(ARSessionState.checkingPermission);

    try {
      var status = await Permission.camera.status;
      if (!mounted) {
        return;
      }

      if (!status.isGranted && requestIfNeeded) {
        status = await Permission.camera.request();
        if (!mounted) {
          return;
        }
      }

      if (status.isGranted) {
        setState(() {
          _isCameraPermissionGranted = true;
          _sessionErrorMessage = null;
          _sessionState = ARSessionState.checkingSupport;
        });
        _initializeSession();
        return;
      }

      setState(() {
        _isCameraPermissionGranted = false;
        _hasInitializedSession = false;
      });

      if (status.isPermanentlyDenied) {
        _setSessionState(ARSessionState.permissionBlocked);
        return;
      }

      if (status.isRestricted) {
        setState(() {
          _sessionState = ARSessionState.error;
          _sessionErrorMessage = 'Camera access is restricted on this device.';
        });
        return;
      }

      _setSessionState(ARSessionState.permissionRequired);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _sessionState = ARSessionState.error;
        _sessionErrorMessage = 'Failed to check camera permission: $error';
      });
    }
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    // The AR location manager is not needed for plane-based local placement.
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    _anchorManager = anchorManager;

    sessionManager.onError = _handleSessionError;
    sessionManager.onPlaneDetected = _handlePlaneDetected;
    sessionManager.onPlaneOrPointTap = _handlePlaneOrPointTap;

    if (_isCameraPermissionGranted) {
      _initializeSession();
    }
  }

  void _initializeSession() {
    final sessionManager = _sessionManager;
    final objectManager = _objectManager;
    if (sessionManager == null ||
        objectManager == null ||
        !_isCameraPermissionGranted ||
        _hasInitializedSession ||
        _isConfiguringSession) {
      return;
    }

    _isConfiguringSession = true;
    _setSessionState(ARSessionState.initializing);

    try {
      sessionManager.onInitialize(
        showAnimatedGuide: true,
        showFeaturePoints: false,
        showPlanes: true,
        showWorldOrigin: false,
        handleTaps: true,
        handlePans: false,
        handleRotation: false,
      );
      objectManager.onInitialize();

      if (!mounted) {
        return;
      }

      setState(() {
        _hasInitializedSession = true;
        _isConfiguringSession = false;
        _sessionErrorMessage = null;
      });
      _syncReadyState();
    } catch (error) {
      _isConfiguringSession = false;
      _handleSessionError('Failed to start AR: $error');
    }
  }

  void _handlePlaneDetected(int planeCount) {
    if (!mounted) {
      return;
    }

    setState(() {
      _planeCount = planeCount;
      _hasHorizontalPlane = planeCount > 0;
    });
    _syncReadyState();
  }

  Future<void> _handlePlaneOrPointTap(
    List<ARHitTestResult> hitTestResults,
  ) async {
    final anchorManager = _anchorManager;
    final objectManager = _objectManager;
    final activeModel = _activeModel;
    if (anchorManager == null ||
        objectManager == null ||
        !_hasInitializedSession ||
        !_hasHorizontalPlane ||
        activeModel == null ||
        _modelNode != null ||
        _sessionState == ARSessionState.placing) {
      return;
    }

    final hit = _firstPlaneHit(hitTestResults);
    if (hit == null) {
      _setSessionState(ARSessionState.readyToPlace);
      return;
    }

    _setSessionState(ARSessionState.placing);

    try {
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final didAddAnchor = await anchorManager.addAnchor(anchor) ?? false;
      if (!mounted) {
        return;
      }

      if (!didAddAnchor) {
        setState(() {
          _sessionState = ARSessionState.error;
          _sessionErrorMessage =
              'Could not create an AR anchor at that position.';
        });
        return;
      }

      var placedModel = activeModel;
      var node = _buildARNode(placedModel);
      var didAddNode = await objectManager.addNode(node, planeAnchor: anchor);
      if (!mounted) {
        return;
      }

      var usedFallbackSource = false;
      if (!(didAddNode ?? false)) {
        final fallbackModel = placedModel.fallbackAfterPlacementFailure();
        if (fallbackModel != null) {
          placedModel = fallbackModel;
          node = _buildARNode(placedModel);
          didAddNode = await objectManager.addNode(node, planeAnchor: anchor);
          usedFallbackSource = didAddNode ?? false;
        }
      }

      if (!(didAddNode ?? false)) {
        anchorManager.removeAnchor(anchor);
        setState(() {
          _sessionState = ARSessionState.error;
          _sessionErrorMessage =
              'Could not attach the generated model to that anchor.';
        });
        return;
      }

      setState(() {
        _modelAnchor = anchor;
        _modelNode = node;
        _activeModel = placedModel;
        _sessionState = ARSessionState.placed;
        _sessionErrorMessage = null;
        // The overlay and the prompt panel stay up: every control that could
        // bring them back — Reset included — lives inside them, so hiding both
        // here left the screen with no way out.
      });
      _sessionManager?.showPlanes(false);
      if (usedFallbackSource) {
        _showTransientMessage(
          'Used the original generation URL because the saved local model '
          'could not be loaded on this device.',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _sessionState = ARSessionState.error;
        _sessionErrorMessage = 'Failed to place the generated model: $error';
      });
    }
  }

  ARNode _buildARNode(MeshyActiveModel model) {
    final scale =
        _generatedModelScale *
        (Platform.isIOS ? _iosPluginModelScaleCompensation : 1.0);
    return ARNode(
      type: model.nodeType,
      uri: model.nodeUri,
      scale: Vector3.all(scale),
      position: Vector3(0.0, 0.01, 0.0),
      rotation: Vector4(0.0, 1.0, 0.0, 0.0),
    );
  }

  ARHitTestResult? _firstPlaneHit(List<ARHitTestResult> hitTestResults) {
    for (final hitTestResult in hitTestResults) {
      if (hitTestResult.type == ARHitTestResultType.plane) {
        return hitTestResult;
      }
    }
    return null;
  }

  void _handleSessionError(String error) {
    if (!mounted) {
      return;
    }

    final normalizedError = error.toLowerCase();
    final nextState =
        normalizedError.contains('not supported') ||
            normalizedError.contains('unsupported') ||
            normalizedError.contains('arcore') ||
            normalizedError.contains('arkit')
        ? ARSessionState.unsupported
        : ARSessionState.error;

    setState(() {
      _isConfiguringSession = false;
      _sessionState = nextState;
      _sessionErrorMessage = error;
    });
  }

  Future<void> _handleGeneratePressed() async {
    final client = _meshyClient;
    if (client == null) {
      setState(() {
        _generationStage = MeshyGenerationStage.missingProxyConfig;
        _generationErrorMessage = _proxyConfiguration.error;
      });
      return;
    }

    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _generationStage = MeshyGenerationStage.error;
        _generationErrorMessage = 'Enter a text prompt before generating.';
      });
      return;
    }

    final imageBytes = _generationImageBytes;
    if (imageBytes == null) {
      setState(() {
        _generationStage = MeshyGenerationStage.error;
        _generationErrorMessage =
            'Take or choose a photo before generating '
            '${_isWorldMode ? 'a world' : 'an object'}.';
      });
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    final generationToken = ++_generationToken;
    await _prepareForNewGeneration();
    if (!_isCurrentGeneration(generationToken)) {
      return;
    }

    setState(() {
      _generationStage = MeshyGenerationStage.submitting;
      _generationErrorMessage = null;
      _currentJob = null;
    });
    _syncReadyState();

    try {
      final createdJob = await client.createJob(
        prompt,
        kind: _generationKind,
        imageBytes: imageBytes,
        steps: _isWorldMode ? _worldSteps : null,
      );
      if (!_isCurrentGeneration(generationToken)) {
        return;
      }

      setState(() {
        _currentJob = createdJob;
      });
      await _pollGenerationJob(generationToken, createdJob.jobId);
    } catch (error) {
      _setGenerationError(generationToken, _normalizeGenerationError(error));
    }
  }

  void _handleWorldStepsChanged(int steps) {
    if (steps == _worldSteps) {
      return;
    }
    setState(() => _worldSteps = steps);
  }

  void _handleKindChanged(String kind) {
    if (kind == _generationKind) {
      return;
    }

    setState(() {
      _generationKind = kind;
      // Don't carry "enter a prompt"/"pick a photo" complaints across a mode
      // switch, but leave a missing-proxy message alone: it is still true.
      if (_generationStage == MeshyGenerationStage.error) {
        _generationStage = MeshyGenerationStage.idle;
        _generationErrorMessage = null;
      }
    });
  }

  Future<void> _handlePickImage(ImageSource source) async {
    // The AR session already owns the camera grant; reuse it rather than
    // opening a second permission flow the user has to answer twice.
    if (source == ImageSource.camera && !_isCameraPermissionGranted) {
      await _ensureCameraPermission();
      if (!mounted || !_isCameraPermissionGranted) {
        return;
      }
    }

    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        maxWidth: _uploadMaxEdge,
        maxHeight: _uploadMaxEdge,
        imageQuality: _uploadJpegQuality,
      );
      if (picked == null || !mounted) {
        return;
      }

      final bytes = await picked.readAsBytes();
      if (!mounted) {
        return;
      }

      setState(() {
        _generationImageBytes = bytes;
        if (_generationStage == MeshyGenerationStage.error) {
          _generationStage = MeshyGenerationStage.idle;
          _generationErrorMessage = null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showTransientMessage('Could not load that photo: $error');
    }
  }

  Future<void> _pollGenerationJob(int generationToken, String jobId) async {
    final client = _meshyClient;
    if (client == null) {
      return;
    }

    var consecutiveFailures = 0;

    while (_isCurrentGeneration(generationToken)) {
      final MeshyGenerationJob job;
      try {
        job = await client.getJob(jobId);
      } catch (error) {
        if (!_isCurrentGeneration(generationToken)) {
          return;
        }

        // A 404 means the proxy genuinely has no such job — it keeps them in
        // memory, so a restart loses them and waiting cannot help. Every other
        // failure is a dropped read while the generation is still running
        // upstream, and abandoning it throws away minutes of GPU work.
        final isMissingJob =
            error is MeshyProxyException && error.statusCode == 404;
        consecutiveFailures++;
        if (isMissingJob || consecutiveFailures >= _maxPollFailures) {
          _setGenerationError(
            generationToken,
            isMissingJob
                ? _normalizeGenerationError(error)
                : 'Lost contact with the server after $consecutiveFailures '
                      'consecutive attempts. '
                      '${_normalizeGenerationError(error)}',
          );
          return;
        }

        setState(() {
          _pollRetryAttempt = consecutiveFailures;
        });
        final backoff = _jobPollInterval * (1 << (consecutiveFailures - 1));
        await _waitForNextPoll(
          generationToken,
          backoff > _maxPollRetryBackoff ? _maxPollRetryBackoff : backoff,
        );
        continue;
      }

      if (!_isCurrentGeneration(generationToken)) {
        return;
      }
      consecutiveFailures = 0;

      setState(() {
        _currentJob = job;
        _pollRetryAttempt = 0;
      });

      if (job.status == MeshyJobStatus.error) {
        _setGenerationError(
          generationToken,
          job.error ?? 'The backend failed to generate a model.',
        );
        return;
      }

      if (job.status == MeshyJobStatus.completed) {
        final panoramaUrl = job.panoramaUrl;
        if (job.kind == 'world' && panoramaUrl != null) {
          // ponytail: worlds stop at a flat full-screen view. The inverted
          // sky sphere (and the caching that would go with it) is the next
          // milestone; nothing is downloaded or placed until then.
          setState(() {
            _panoramaUrl = panoramaUrl;
            _generationStage = MeshyGenerationStage.ready;
            _generationErrorMessage = null;
          });
          return;
        }

        final glbUrl = job.glbUrl;
        if (glbUrl == null || glbUrl.isEmpty) {
          _setGenerationError(
            generationToken,
            'The backend completed the job without returning a GLB URL.',
          );
          return;
        }

        var activeModel = MeshyActiveModel.remoteSession(
          id: job.jobId,
          prompt: job.prompt,
          glbUrl: glbUrl,
          thumbnailUrl: job.thumbnailUrl,
        );
        String? cacheWarningMessage;
        try {
          final cacheResult = await _modelHistoryStore.cacheCompletedJob(
            job: job,
          );
          activeModel = MeshyActiveModel.fromRecord(
            cacheResult.record,
            runtime: _placementRuntime,
          );
          final records = await _modelHistoryStore.loadRecords();
          if (mounted) {
            setState(() {
              _recentModels
                ..clear()
                ..addAll(records);
            });
          }
        } catch (error) {
          cacheWarningMessage =
              'Model ready for this session, but it could not be saved '
              'locally for reuse: $error';
        }

        if (!_isCurrentGeneration(generationToken)) {
          return;
        }
        setState(() {
          _activeModel = activeModel;
          _generationStage = MeshyGenerationStage.ready;
          _generationErrorMessage = null;
        });
        _syncReadyState();
        if (cacheWarningMessage != null) {
          _showTransientMessage(cacheWarningMessage);
        }
        return;
      }

      setState(() {
        _generationStage = _mapJobStatusToGenerationStage(job.status);
        _generationErrorMessage = null;
      });

      await _waitForNextPoll(generationToken, _jobPollInterval);
    }
  }

  /// Sleeps in poll-interval slices so a long retry backoff never delays
  /// cancellation: the loop still notices a changed [_generationToken] or an
  /// unmounted widget within one poll interval, exactly as before the retries
  /// existed.
  Future<void> _waitForNextPoll(int generationToken, Duration delay) async {
    var remaining = delay;
    while (remaining > Duration.zero && _isCurrentGeneration(generationToken)) {
      final slice = remaining < _jobPollInterval ? remaining : _jobPollInterval;
      await Future<void>.delayed(slice);
      remaining -= slice;
    }
  }

  Future<void> _prepareForNewGeneration() async {
    await _removePlacedModel();

    setState(() {
      _currentJob = null;
      _modelAnchor = null;
      _modelNode = null;
      _activeModel = null;
      _sessionErrorMessage = null;
      _panoramaUrl = null;
      _pollRetryAttempt = 0;
    });
    _sessionManager?.showPlanes(true);
  }

  Future<void> _handleRecentModelSelected(MeshyModelRecord record) async {
    if (_isGenerating) {
      return;
    }

    _generationToken++;
    await _removePlacedModel();
    await _modelHistoryStore.markUsed(record.id);
    final records = await _modelHistoryStore.loadRecords();
    if (!mounted) {
      return;
    }

    _promptController.value = TextEditingValue(
      text: record.prompt,
      selection: TextSelection.collapsed(offset: record.prompt.length),
    );

    setState(() {
      _currentJob = null;
      _modelAnchor = null;
      _modelNode = null;
      _activeModel = MeshyActiveModel.fromRecord(
        record,
        runtime: _placementRuntime,
      );
      _generationStage = MeshyGenerationStage.ready;
      _generationErrorMessage = null;
      _sessionErrorMessage = null;
      _generationKind = 'object';
      _panoramaUrl = null;
      _recentModels
        ..clear()
        ..addAll(records);
    });
    _sessionManager?.showPlanes(true);
    _syncReadyState();
  }

  Future<void> _resetPlacedModel() async {
    await _removePlacedModel();
    if (!mounted) {
      return;
    }

    setState(() {
      _modelAnchor = null;
      _modelNode = null;
      _sessionErrorMessage = null;
    });
    _sessionManager?.showPlanes(true);
    _syncReadyState();
  }

  Future<void> _removePlacedModel() async {
    final objectManager = _objectManager;
    final anchorManager = _anchorManager;
    final modelNode = _modelNode;
    final modelAnchor = _modelAnchor;

    try {
      if (modelNode != null) {
        objectManager?.removeNode(modelNode);
      }
      if (modelAnchor != null) {
        anchorManager?.removeAnchor(modelAnchor);
      }
    } catch (_) {
      // Cleanup failures are non-fatal for the next placement attempt.
    }
  }

  Future<void> _handlePrimaryAction() async {
    if (_sessionState == ARSessionState.permissionBlocked) {
      await openAppSettings();
      return;
    }

    await _ensureCameraPermission();
  }

  void _syncReadyState() {
    if (!mounted ||
        !_isCameraPermissionGranted ||
        _sessionState == ARSessionState.permissionRequired ||
        _sessionState == ARSessionState.permissionBlocked ||
        _sessionState == ARSessionState.unsupported ||
        _sessionState == ARSessionState.placing ||
        _sessionState == ARSessionState.error) {
      return;
    }

    setState(() {
      if (_modelNode != null) {
        _sessionState = ARSessionState.placed;
      } else if (!_hasInitializedSession || _isConfiguringSession) {
        _sessionState = ARSessionState.initializing;
      } else if (_hasGeneratedModel && _hasHorizontalPlane) {
        _sessionState = ARSessionState.readyToPlace;
      } else {
        _sessionState = ARSessionState.scanning;
      }
    });
  }

  void _setGenerationError(int generationToken, String message) {
    if (!_isCurrentGeneration(generationToken)) {
      return;
    }

    setState(() {
      _generationStage = _meshyClient == null
          ? MeshyGenerationStage.missingProxyConfig
          : MeshyGenerationStage.error;
      _generationErrorMessage = message;
      _pollRetryAttempt = 0;
    });
    _syncReadyState();
  }

  void _setSessionState(ARSessionState state) {
    if (!mounted) {
      return;
    }

    setState(() {
      _sessionState = state;
      if (state != ARSessionState.error &&
          state != ARSessionState.unsupported) {
        _sessionErrorMessage = null;
      }
    });
  }

  MeshyGenerationStage _mapJobStatusToGenerationStage(MeshyJobStatus status) {
    switch (status) {
      case MeshyJobStatus.submitting:
        return MeshyGenerationStage.submitting;
      case MeshyJobStatus.previewing:
        return MeshyGenerationStage.previewing;
      case MeshyJobStatus.refining:
        return MeshyGenerationStage.refining;
      case MeshyJobStatus.completed:
        return MeshyGenerationStage.ready;
      case MeshyJobStatus.error:
        return MeshyGenerationStage.error;
    }
  }

  String _normalizeGenerationError(Object error) {
    if (error is MeshyProxyException) {
      return error.message;
    }
    return error.toString();
  }

  bool _isCurrentGeneration(int generationToken) {
    return mounted && generationToken == _generationToken;
  }

  IconData get _statusIcon {
    if (_sessionState == ARSessionState.permissionRequired ||
        _sessionState == ARSessionState.permissionBlocked) {
      return Icons.videocam_rounded;
    }
    if (_sessionState == ARSessionState.unsupported ||
        _sessionState == ARSessionState.error ||
        _generationStage == MeshyGenerationStage.error ||
        _generationStage == MeshyGenerationStage.missingProxyConfig) {
      return Icons.warning_amber_rounded;
    }
    if (_sessionState == ARSessionState.readyToPlace ||
        _sessionState == ARSessionState.placing ||
        _sessionState == ARSessionState.placed) {
      return Icons.touch_app_rounded;
    }
    return Icons.view_in_ar_rounded;
  }

  String get _planeChipLabel {
    if (_sessionState == ARSessionState.permissionRequired ||
        _sessionState == ARSessionState.permissionBlocked ||
        _sessionState == ARSessionState.checkingPermission) {
      return 'Camera permission pending';
    }
    if (_sessionState == ARSessionState.checkingSupport ||
        _sessionState == ARSessionState.initializing) {
      return 'Preparing AR session';
    }
    if (_sessionState == ARSessionState.unsupported ||
        _sessionState == ARSessionState.error) {
      return 'AR unavailable';
    }
    return _hasHorizontalPlane
        ? 'Horizontal plane detected'
        : 'Scanning for horizontal plane';
  }

  String get _generationChipLabel {
    if (_pollRetryAttempt > 0) {
      return 'Reconnecting $_pollRetryAttempt/$_maxPollFailures';
    }

    final stageLabel = _currentMeshyStageLabel;
    final progressLabel = _currentProgressLabel;

    switch (_generationStage) {
      case MeshyGenerationStage.missingProxyConfig:
        return 'Proxy URL missing';
      case MeshyGenerationStage.submitting:
        return 'Submitting prompt';
      case MeshyGenerationStage.previewing:
        return stageLabel == null || progressLabel == null
            ? 'Preview running'
            : '$stageLabel $progressLabel';
      case MeshyGenerationStage.refining:
        return stageLabel == null || progressLabel == null
            ? 'Refine running'
            : '$stageLabel $progressLabel';
      case MeshyGenerationStage.ready:
        return 'Model ready';
      case MeshyGenerationStage.error:
        return 'Generation error';
      case MeshyGenerationStage.idle:
        return 'Ready for prompt';
    }
  }

  @override
  void dispose() {
    _generationToken++;
    _promptController
      ..removeListener(_handlePromptChanged)
      ..dispose();
    WidgetsBinding.instance.removeObserver(this);
    _modelHistoryStore.close();
    _sessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panoramaUrl = _panoramaUrl;
    final canGenerate =
        !_isGenerating &&
        _meshyClient != null &&
        _promptController.text.trim().isNotEmpty &&
        _generationImageBytes != null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: _backgroundColor),
          if (_isCameraPermissionGranted)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),
          if (panoramaUrl == null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 220),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ARStatusOverlay(
                    title: _statusTitle,
                    message: _statusMessage,
                    icon: _statusIcon,
                    planeChipLabel: _planeChipLabel,
                    generationChipLabel: _generationChipLabel,
                    placementChipLabel: _modelNode != null
                        ? 'Model anchored'
                        : 'Single model mode',
                    planeCount: _planeCount,
                    primaryActionLabel: _primaryActionLabel,
                    onPrimaryAction: _primaryActionLabel == null
                        ? null
                        : _handlePrimaryAction,
                    showReset: _modelNode != null,
                    onReset: _resetPlacedModel,
                  ),
                ),
              ),
            ),
          if (panoramaUrl == null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SingleChildScrollView(
                    child: MeshyPromptPanel(
                      promptController: _promptController,
                      helperText: _promptHelperText,
                      generateLabel: _generateButtonLabel,
                      onGenerate: canGenerate ? _handleGeneratePressed : null,
                      recentModels: _recentModels,
                      isLoadingRecentModels: _isLoadingHistory,
                      onSelectRecentModel: _isGenerating
                          ? null
                          : _handleRecentModelSelected,
                      activeModelId: _activeModel?.id,
                      kind: _generationKind,
                      onKindChanged: _isGenerating ? null : _handleKindChanged,
                      imageBytes: _generationImageBytes,
                      onPickImage: _isGenerating ? null : _handlePickImage,
                      worldSteps: _worldSteps,
                      onWorldStepsChanged: _isGenerating
                          ? null
                          : _handleWorldStepsChanged,
                    ),
                  ),
                ),
              ),
            ),
          if (panoramaUrl != null)
            _PanoramaViewer(
              url: panoramaUrl,
              onDismiss: () => setState(() => _panoramaUrl = null),
            ),
        ],
      ),
    );
  }

  String get _generateButtonLabel {
    switch (_generationStage) {
      case MeshyGenerationStage.idle:
      case MeshyGenerationStage.ready:
      case MeshyGenerationStage.error:
        return _isWorldMode ? 'Generate world' : 'Generate model';
      case MeshyGenerationStage.missingProxyConfig:
        return 'Proxy required';
      case MeshyGenerationStage.submitting:
        return 'Submitting...';
      case MeshyGenerationStage.previewing:
        return 'Previewing...';
      case MeshyGenerationStage.refining:
        return 'Refining...';
    }
  }

  String _buildProgressStatusMessage({required String stageFallback}) {
    final stageLabel = _currentMeshyStageLabel;
    final progressLabel = _currentProgressLabel;
    final rawStatus = _currentJob?.meshyStatus;
    final updateAgeLabel = _lastProgressUpdateLabel;

    if (stageLabel == null && progressLabel == null && rawStatus == null) {
      return stageFallback;
    }

    final baseMessage = progressLabel == null
        ? '${stageLabel ?? 'Generation'} is still running upstream.'
        : '${stageLabel ?? 'Generation'} is $progressLabel complete.';
    final statusMessage = rawStatus == null
        ? ''
        : ' Backend status: $rawStatus.';
    final staleMessage = updateAgeLabel == null
        ? ''
        : _isProgressUpdateStale
        ? ' Progress has not changed for $updateAgeLabel.'
        : ' Last progress update $updateAgeLabel.';

    return '$baseMessage$statusMessage$staleMessage'.trim();
  }

  String _buildProgressHelperText({required String fallback}) {
    final taskId = _currentMeshyTaskId;
    final rawStatus = _currentJob?.meshyStatus;
    final progressLabel = _currentProgressLabel;
    final updateAgeLabel = _lastProgressUpdateLabel;

    if (taskId == null && rawStatus == null && progressLabel == null) {
      return fallback;
    }

    final parts = <String>[
      if (taskId != null) 'Task $taskId',
      if (rawStatus != null) 'is $rawStatus',
      if (progressLabel != null) 'at $progressLabel',
    ];
    final body = parts.join(' ');
    final timing = updateAgeLabel == null
        ? ''
        : _isProgressUpdateStale
        ? ' Progress has been unchanged for $updateAgeLabel.'
        : ' Last progress update $updateAgeLabel.';

    return '$body.$timing'.trim();
  }

  String? get _lastProgressUpdateLabel {
    final updatedAt = _currentJob?.updatedAt;
    if (updatedAt == null) {
      return null;
    }

    final diff = DateTime.now().toUtc().difference(updatedAt);
    if (diff.inSeconds < 5) {
      return 'just now';
    }
    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    }
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    }
    return '${diff.inHours}h ago';
  }

  void _showTransientMessage(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class ARStatusOverlay extends StatelessWidget {
  const ARStatusOverlay({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.planeChipLabel,
    required this.generationChipLabel,
    required this.placementChipLabel,
    required this.planeCount,
    required this.primaryActionLabel,
    required this.onPrimaryAction,
    required this.showReset,
    required this.onReset,
  });

  final String title;
  final String message;
  final IconData icon;
  final String planeChipLabel;
  final String generationChipLabel;
  final String placementChipLabel;
  final int planeCount;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool showReset;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _OverlayChip(
                  label: planeChipLabel,
                  icon: Icons.layers_outlined,
                ),
                _OverlayChip(
                  label: generationChipLabel,
                  icon: Icons.auto_awesome_rounded,
                ),
                _OverlayChip(
                  label: placementChipLabel,
                  icon: showReset
                      ? Icons.lock_outline_rounded
                      : Icons.radio_button_checked_rounded,
                ),
                _OverlayChip(
                  label: planeCount == 0
                      ? 'No planes yet'
                      : '$planeCount plane${planeCount == 1 ? '' : 's'} tracked',
                  icon: Icons.grid_view_rounded,
                ),
              ],
            ),
            if (primaryActionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onPrimaryAction,
                icon: Icon(
                  primaryActionLabel == 'Open settings'
                      ? Icons.settings_rounded
                      : Icons.videocam_rounded,
                ),
                label: Text(primaryActionLabel!),
              ),
            ],
            if (showReset) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset placement'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MeshyPromptPanel extends StatelessWidget {
  const MeshyPromptPanel({
    super.key,
    required this.promptController,
    required this.helperText,
    required this.generateLabel,
    required this.onGenerate,
    this.recentModels = const <MeshyModelRecord>[],
    this.isLoadingRecentModels = false,
    this.onSelectRecentModel,
    this.activeModelId,
    this.kind = 'object',
    this.onKindChanged,
    this.imageBytes,
    this.onPickImage,
    this.worldSteps = 12,
    this.onWorldStepsChanged,
  });

  final TextEditingController promptController;
  final String helperText;
  final String generateLabel;
  final VoidCallback? onGenerate;
  final List<MeshyModelRecord> recentModels;
  final bool isLoadingRecentModels;
  final ValueChanged<MeshyModelRecord>? onSelectRecentModel;
  final String? activeModelId;

  /// `'object'` or `'world'`.
  final String kind;
  final ValueChanged<String>? onKindChanged;

  /// The source photo. Both self-hosted generation models are image-conditioned.
  final Uint8List? imageBytes;
  final ValueChanged<ImageSource>? onPickImage;
  final int worldSteps;
  final ValueChanged<int>? onWorldStepsChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showRecentModels = isLoadingRecentModels || recentModels.isNotEmpty;
    final isWorldMode = kind == 'world';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF10151F).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showRecentModels) ...[
              Text(
                'Recent Models',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 92,
                child: isLoadingRecentModels
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemBuilder: (context, index) {
                          final record = recentModels[index];
                          return _RecentModelCard(
                            record: record,
                            isActive: activeModelId == record.id,
                            onTap: onSelectRecentModel == null
                                ? null
                                : () => onSelectRecentModel!(record),
                          );
                        },
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: 10),
                        itemCount: recentModels.length,
                      ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Generation',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Object'),
                  avatar: const Icon(Icons.view_in_ar_rounded, size: 18),
                  selected: !isWorldMode,
                  onSelected: onKindChanged == null
                      ? null
                      : (_) => onKindChanged!('object'),
                ),
                ChoiceChip(
                  label: const Text('World'),
                  avatar: const Icon(Icons.panorama_photosphere, size: 18),
                  selected: isWorldMode,
                  onSelected: onKindChanged == null
                      ? null
                      : (_) => onKindChanged!('world'),
                ),
              ],
            ),
            if (isWorldMode) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Fast · 12 steps'),
                    selected: worldSteps == 12,
                    onSelected: onWorldStepsChanged == null
                        ? null
                        : (_) => onWorldStepsChanged!(12),
                  ),
                  ChoiceChip(
                    label: const Text('Quality · 40 steps'),
                    selected: worldSteps == 40,
                    onSelected: onWorldStepsChanged == null
                        ? null
                        : (_) => onWorldStepsChanged!(40),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _GenerationPhotoPicker(
              kind: kind,
              imageBytes: imageBytes,
              onPick: onPickImage,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: promptController,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: isWorldMode
                    ? 'Example: a sunlit alpine meadow at golden hour'
                    : 'Name this object for your model history',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                ),
                filled: true,
                fillColor: Colors.black.withValues(alpha: 0.22),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              helperText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.82),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(generateLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Both models need a photo. Gallery sits next to the camera because the demo
/// may run indoors.
class _GenerationPhotoPicker extends StatelessWidget {
  const _GenerationPhotoPicker({
    required this.kind,
    required this.imageBytes,
    required this.onPick,
  });

  final String kind;
  final Uint8List? imageBytes;
  final ValueChanged<ImageSource>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = imageBytes;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: 64,
            child: bytes == null
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Icon(
                      Icons.image_outlined,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  )
                : Image.memory(bytes, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                bytes == null
                    ? kind == 'world'
                          ? 'Add a photo to expand into a 360 world.'
                          : 'Add a photo to turn into a 3D object.'
                    : 'Photo ready (${(bytes.length / 1024).round()} KB).',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onPick == null
                        ? null
                        : () => onPick!(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded, size: 18),
                    label: const Text('Camera'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onPick == null
                        ? null
                        : () => onPick!(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded, size: 18),
                    label: const Text('Gallery'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// M2 stops here: the panorama is shown flat over the AR view. The inverted sky
/// sphere is the next milestone.
class _PanoramaViewer extends StatelessWidget {
  const _PanoramaViewer({required this.url, required this.onDismiss});

  final String url;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            maxScale: 6,
            child: Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'The panorama could not be loaded: $error',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Dismiss'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentModelCard extends StatelessWidget {
  const _RecentModelCard({
    required this.record,
    required this.isActive,
    required this.onTap,
  });

  final MeshyModelRecord record;
  final bool isActive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = isActive
        ? theme.colorScheme.primary
        : Colors.white.withValues(alpha: 0.12);

    return SizedBox(
      width: 200,
      child: Material(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatRecordTimestamp(record.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatRecordTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
