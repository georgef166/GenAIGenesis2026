import 'dart:async';

import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'meshy_proxy_client.dart';

const _backgroundColor = Color(0xFF02040a);

const _jobPollInterval = Duration(seconds: 3);
const _generatedModelScale = 0.14;

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
  String? _generatedModelUrl;
  bool _isCameraPermissionGranted = false;
  bool _hasHorizontalPlane = false;
  bool _hasInitializedSession = false;
  bool _isConfiguringSession = false;
  int _planeCount = 0;
  int _generationToken = 0;
  bool _showPlacementUi = true;

  MeshyProxyClient? get _meshyClient => _proxyConfiguration.client;

  bool get _isGenerating =>
      _generationStage == MeshyGenerationStage.submitting ||
      _generationStage == MeshyGenerationStage.previewing ||
      _generationStage == MeshyGenerationStage.refining;

  bool get _hasGeneratedModel => _generatedModelUrl != null;

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
        return 'Anchoring the generated Meshy model to the detected plane...';
      case ARSessionState.placed:
        return 'Model placed. Reset to place it again or generate a new prompt.';
      case ARSessionState.scanning:
      case ARSessionState.readyToPlace:
        break;
    }

    switch (_generationStage) {
      case MeshyGenerationStage.missingProxyConfig:
        return _proxyConfiguration.error ??
            'The app is missing the Meshy proxy base URL.';
      case MeshyGenerationStage.submitting:
        return 'Sending your prompt to the local Meshy proxy...';
      case MeshyGenerationStage.previewing:
        return _buildProgressStatusMessage(
          stageFallback: 'Meshy is creating a preview model from your prompt.',
        );
      case MeshyGenerationStage.refining:
        return _buildProgressStatusMessage(
          stageFallback:
              'Meshy is refining the preview into a textured GLB model.',
        );
      case MeshyGenerationStage.error:
        return _generationErrorMessage ?? 'Meshy could not generate a model.';
      case MeshyGenerationStage.ready:
        return _hasHorizontalPlane
            ? 'Tap a horizontal surface to place the generated model.'
            : 'Model ready. Move your phone slowly to detect a flat surface.';
      case MeshyGenerationStage.idle:
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
        return _proxyConfiguration.error ??
            'Set MESHY_PROXY_BASE_URL before running the app.';
      case MeshyGenerationStage.submitting:
        return 'Prompt accepted. Waiting for the preview task to start.'
            '$currentJobSuffix';
      case MeshyGenerationStage.previewing:
        return _buildProgressHelperText(
          fallback:
              'Meshy preview task is running on the local proxy.'
              '$currentJobSuffix',
        );
      case MeshyGenerationStage.refining:
        return _buildProgressHelperText(
          fallback:
              'Preview complete. Meshy is refining the model now.'
              '$currentJobSuffix',
        );
      case MeshyGenerationStage.ready:
        return 'Meshy model ready. Tap a plane to place it.';
      case MeshyGenerationStage.error:
        return _generationErrorMessage ?? 'Meshy generation failed.';
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
    if (anchorManager == null ||
        objectManager == null ||
        !_hasInitializedSession ||
        !_hasHorizontalPlane ||
        !_hasGeneratedModel ||
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

      final node = ARNode(
        type: NodeType.webGLB,
        uri: _generatedModelUrl!,
        scale: Vector3.all(_generatedModelScale),
        position: Vector3(0.0, 0.01, 0.0),
        rotation: Vector4(0.0, 1.0, 0.0, 0.0),
      );

      final didAddNode = await objectManager.addNode(node, planeAnchor: anchor);
      if (!mounted) {
        return;
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
        _sessionState = ARSessionState.placed;
        _sessionErrorMessage = null;
        _showPlacementUi = false;
      });
      _sessionManager?.showPlanes(false);
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
      final createdJob = await client.createJob(prompt);
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

  Future<void> _pollGenerationJob(int generationToken, String jobId) async {
    final client = _meshyClient;
    if (client == null) {
      return;
    }

    while (_isCurrentGeneration(generationToken)) {
      try {
        final job = await client.getJob(jobId);
        if (!_isCurrentGeneration(generationToken)) {
          return;
        }

        setState(() {
          _currentJob = job;
        });

        if (job.status == MeshyJobStatus.error) {
          _setGenerationError(
            generationToken,
            job.error ?? 'Meshy failed to generate a model.',
          );
          return;
        }

        if (job.status == MeshyJobStatus.completed) {
          final glbUrl = job.glbUrl;
          if (glbUrl == null || glbUrl.isEmpty) {
            _setGenerationError(
              generationToken,
              'Meshy completed the job without returning a GLB URL.',
            );
            return;
          }

          setState(() {
            _generatedModelUrl = glbUrl;
            _generationStage = MeshyGenerationStage.ready;
            _generationErrorMessage = null;
          });
          _syncReadyState();
          return;
        }

        setState(() {
          _generationStage = _mapJobStatusToGenerationStage(job.status);
          _generationErrorMessage = null;
        });
      } catch (error) {
        _setGenerationError(generationToken, _normalizeGenerationError(error));
        return;
      }

      await Future<void>.delayed(_jobPollInterval);
    }
  }

  Future<void> _prepareForNewGeneration() async {
    await _removePlacedModel();

    setState(() {
      _currentJob = null;
      _modelAnchor = null;
      _modelNode = null;
      _generatedModelUrl = null;
      _sessionErrorMessage = null;
      _showPlacementUi = true;
    });
    _sessionManager?.showPlanes(true);
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
      _showPlacementUi = true;
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
    _sessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canGenerate =
        !_isGenerating &&
        _meshyClient != null &&
        _promptController.text.trim().isNotEmpty;

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
          if (_showPlacementUi)
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
          if (_showPlacementUi)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: MeshyPromptPanel(
                    promptController: _promptController,
                    helperText: _promptHelperText,
                    generateLabel: _generateButtonLabel,
                    onGenerate: canGenerate ? _handleGeneratePressed : null,
                  ),
                ),
              ),
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
        return 'Generate model';
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
        ? '${stageLabel ?? 'Meshy'} is still running upstream.'
        : '${stageLabel ?? 'Meshy'} is $progressLabel complete.';
    final statusMessage = rawStatus == null ? '' : ' Meshy status: $rawStatus.';
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
  });

  final TextEditingController promptController;
  final String helperText;
  final String generateLabel;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            Text(
              'Meshy Prompt',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: promptController,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Example: a carved jade fox statue',
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
