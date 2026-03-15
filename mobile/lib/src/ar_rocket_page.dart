import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:genai/rocket_parts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

const _backgroundColor = Color(0xFF02040a);
const _primaryColor = Color(0xFF00ffff);
const _lightColor = Color(0xFF80ffde);

// ---------------------------------------------------------------------------
// Asset path
// ---------------------------------------------------------------------------
const _rocketModelAssetPath = 'assets/models/saturn_v_-_nasa/scene.gltf';
const _cloudModelAssetPath = 'assets/models/cloud.gltf';
const _flameSpriteModelAssetPath = 'assets/models/flame_sprite.gltf';
const _iosPluginModelScaleCompensation = 100.0;

// ---------------------------------------------------------------------------
// Placement state machine
// ---------------------------------------------------------------------------

enum ARPlacementState {
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

// ---------------------------------------------------------------------------
// Launch animation constants
// ---------------------------------------------------------------------------

enum LaunchPhase { idle, lifting, gone }

const _kCloudLayerHeight = 1.4;
const _kIdleBeforeCountdownSeconds = 1.0;
const _kAscentInitialSpeedMps = 0.9;
const _kAscentCruiseSpeedMps = 2.6;
const _kAscentRampSeconds = 3.5;
const _kPlumeHiddenY = -10.0;
const _kEngineBaseY = -0.24;
const _kEngineClusterRadius = 0.11;

// ---------------------------------------------------------------------------
// Main AR page
// ---------------------------------------------------------------------------

class ARRocketPage extends StatefulWidget {
  const ARRocketPage({super.key});

  @override
  State<ARRocketPage> createState() => _ARRocketPageState();
}

class _ARRocketPageState extends State<ARRocketPage>
    with WidgetsBindingObserver {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;

  ARPlaneAnchor? _rocketAnchor;
  ARNode? _rocketNode;

  ARPlacementState _state = ARPlacementState.checkingPermission;
  String _message = 'Checking camera permission...';
  bool _isCameraPermissionGranted = false;
  bool _hasHorizontalPlane = false;
  bool _hasInitializedSession = false;
  bool _isConfiguringSession = false;
  int _planeCount = 0;
  bool _showPlacementUi = true;

  // Launch animation state
  Timer? _launchTimer;
  LaunchPhase _launchPhase = LaunchPhase.idle;
  double _launchElapsed = 0.0;
  double _liftoffElapsed = 0.0;
  double _launchOffset = 0.0;
  bool _countdownPlayed = false;
  bool _countdownCompleted = false;
  bool _liftoffTriggered = false;
  bool _engineStarted = false;
  ARNode? _cloudNode;
  bool _cloudVisible = false;
  final List<ARNode> _flameNodes = <ARNode>[];
  bool _flamesVisible = false;

  final List<Vector3> _engineOffsets = <Vector3>[
    Vector3(0.0, 0.0, 0.0),
    Vector3(_kEngineClusterRadius, 0.0, _kEngineClusterRadius),
    Vector3(-_kEngineClusterRadius, 0.0, _kEngineClusterRadius),
    Vector3(_kEngineClusterRadius, 0.0, -_kEngineClusterRadius),
    Vector3(-_kEngineClusterRadius, 0.0, -_kEngineClusterRadius),
  ];

  final AudioPlayer _countdownPlayer = AudioPlayer();
  final AudioPlayer _enginePlayer = AudioPlayer();
  StreamSubscription<void>? _countdownCompleteSub;
  StreamSubscription<PlayerState>? _engineStateSub;
  bool _engineAudioRunning = false;
  static const _engineBaseVolume = 0.88;

  Vector3 get _rocketScale => Platform.isIOS
      ? Vector3(
          0.1 * _iosPluginModelScaleCompensation,
          0.1 * _iosPluginModelScaleCompensation,
          0.1 * _iosPluginModelScaleCompensation,
        )
      : Vector3(0.1, 0.1, 0.1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enginePlayer.setReleaseMode(ReleaseMode.loop);
    _enginePlayer.setVolume(_engineBaseVolume);
    _engineStateSub = _enginePlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.stopped || state == PlayerState.disposed) {
        _engineAudioRunning = false;
      }
    });
    _countdownCompleteSub = _countdownPlayer.onPlayerComplete.listen((_) {
      _countdownCompleted = true;
      _triggerLiftoffIfReady();
    });
    _ensureCameraPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureCameraPermission(requestIfNeeded: false);
    }
  }

  // -------------------------------------------------------------------------
  // Permission helpers
  // -------------------------------------------------------------------------

  Future<void> _ensureCameraPermission({bool requestIfNeeded = true}) async {
    _setOverlayState(
      ARPlacementState.checkingPermission,
      requestIfNeeded
          ? 'Checking camera permission...'
          : 'Refreshing camera permission...',
    );

    try {
      var status = await Permission.camera.status;
      if (!mounted) return;

      if (!status.isGranted && requestIfNeeded) {
        _setOverlayState(
          ARPlacementState.checkingPermission,
          'Requesting camera permission...',
        );
        status = await Permission.camera.request();
        if (!mounted) return;
      }

      if (status.isGranted) {
        setState(() {
          _isCameraPermissionGranted = true;
          if (!_hasInitializedSession && !_isConfiguringSession) {
            _state = ARPlacementState.checkingSupport;
            _message = 'Opening the AR camera...';
          }
        });
        return;
      }

      setState(() {
        _isCameraPermissionGranted = false;
        _hasInitializedSession = false;
      });

      if (status.isPermanentlyDenied) {
        _setOverlayState(
          ARPlacementState.permissionBlocked,
          'Camera access is blocked. Open settings to allow the app to use AR.',
        );
        return;
      }

      if (status.isRestricted) {
        _setOverlayState(
          ARPlacementState.error,
          'Camera access is restricted on this device.',
        );
        return;
      }

      _setOverlayState(
        ARPlacementState.permissionRequired,
        'Camera access is required before the AR session can start.',
      );
    } catch (error) {
      if (!mounted) return;
      _setOverlayState(
        ARPlacementState.error,
        'Failed to check camera permission: $error',
      );
    }
  }

  // -------------------------------------------------------------------------
  // AR session callbacks
  // -------------------------------------------------------------------------

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
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
    _setOverlayState(
      ARPlacementState.initializing,
      'Initializing the AR session...',
    );

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

      if (!mounted) return;

      setState(() {
        _hasInitializedSession = true;
        _isConfiguringSession = false;
        if (_rocketNode != null) {
          _state = ARPlacementState.placed;
          _message =
              'Rocket placed. Tap a part to learn about it, or use Reset to move it.';
        } else if (_hasHorizontalPlane) {
          _state = ARPlacementState.readyToPlace;
          _message = 'Tap a horizontal surface to place the rocket.';
        } else {
          _state = ARPlacementState.scanning;
          _message = 'Move your phone slowly to detect a flat surface.';
        }
      });
    } catch (error) {
      _isConfiguringSession = false;
      _handleSessionError('Failed to start AR: $error');
    }
  }

  void _handlePlaneDetected(int planeCount) {
    if (!mounted) return;

    setState(() {
      _planeCount = planeCount;
      _hasHorizontalPlane = planeCount > 0;

      if (_rocketNode != null ||
          _state == ARPlacementState.placing ||
          _state == ARPlacementState.permissionRequired ||
          _state == ARPlacementState.permissionBlocked ||
          _state == ARPlacementState.unsupported ||
          _state == ARPlacementState.error) {
        return;
      }

      if (_hasHorizontalPlane) {
        _state = ARPlacementState.readyToPlace;
        _message = 'Tap a horizontal surface to place the rocket.';
      } else if (_hasInitializedSession) {
        _state = ARPlacementState.scanning;
        _message = 'Move your phone slowly to detect a flat surface.';
      }
    });
  }

  Future<void> _handlePlaneOrPointTap(
    List<ARHitTestResult> hitTestResults,
  ) async {
    final anchorManager = _anchorManager;
    final objectManager = _objectManager;

    // Once the rocket is placed, any tap on the AR view opens the parts sheet.
    if (_rocketNode != null && _state == ARPlacementState.placed) {
      _showPartsSheet();
      return;
    }

    if (anchorManager == null ||
        objectManager == null ||
        !_hasInitializedSession ||
        !_hasHorizontalPlane ||
        _rocketNode != null ||
        _state == ARPlacementState.placing) {
      return;
    }

    final hit = _firstPlaneHit(hitTestResults);
    if (hit == null) {
      _setOverlayState(
        ARPlacementState.readyToPlace,
        'Tap directly on a horizontal surface to place the rocket.',
      );
      return;
    }

    _setOverlayState(ARPlacementState.placing, 'Placing the rocket...');

    try {
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final didAddAnchor = await anchorManager.addAnchor(anchor) ?? false;
      if (!mounted) return;

      if (!didAddAnchor) {
        _setOverlayState(
          ARPlacementState.error,
          'Could not create an AR anchor at that position.',
        );
        return;
      }

      // Scale the rocket to ~20 cm — tune this once your model is in place.
      final node = ARNode(
        type: NodeType.localGLTF2,
        uri: _rocketModelAssetPath,
        scale: _rocketScale,
        position: Vector3(0.0, 0.0, 0.0),
        rotation: Vector4(1.0, 0.0, 0.0, 0.0),
      );

      final didAddNode = await objectManager.addNode(node, planeAnchor: anchor);
      if (!mounted) return;

      if (!(didAddNode ?? false)) {
        anchorManager.removeAnchor(anchor);
        _setOverlayState(
          ARPlacementState.error,
          'Could not attach the rocket model to that anchor.',
        );
        return;
      }

      setState(() {
        _rocketAnchor = anchor;
        _rocketNode = node;
        _state = ARPlacementState.placed;
        _showPlacementUi = false;
        _message = 'Rocket placed! Launch begins in 1 second…';
      });
      _sessionManager?.showPlanes(false);

      // Add cloud layer (parked off-scene until needed).
      await _addCloudLayer(anchor);
      // Add multi-engine flame sprites (parked off-scene until liftoff).
      await _addEngineFlameNodes(anchor);
      // Begin launch countdown.
      _startLaunchSequence();
    } catch (error) {
      if (!mounted) return;
      _setOverlayState(
        ARPlacementState.error,
        'Failed to place the rocket: $error',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Parts explorer sheets
  // -------------------------------------------------------------------------

  /// Shows a scrollable bottom sheet listing all rocket parts.
  void _showPartsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RocketPartsSheet(
        parts: kRocketParts,
        onPartSelected: (part) {
          // Pop the list sheet first, then push the detail sheet.
          Navigator.of(context).pop();
          _showPartDetailSheet(part);
        },
      ),
    );
  }

  /// Shows a detail bottom sheet for a single [RocketPart].
  void _showPartDetailSheet(RocketPart part) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PartDetailSheet(part: part),
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  ARHitTestResult? _firstPlaneHit(List<ARHitTestResult> hitTestResults) {
    for (final hit in hitTestResults) {
      if (hit.type == ARHitTestResultType.plane) return hit;
    }
    return null;
  }

  void _handleSessionError(String error) {
    if (!mounted) return;

    final normalised = error.toLowerCase();
    final nextState =
        normalised.contains('not supported') ||
            normalised.contains('unsupported') ||
            normalised.contains('arcore') ||
            normalised.contains('arkit')
        ? ARPlacementState.unsupported
        : ARPlacementState.error;

    setState(() {
      _isConfiguringSession = false;
      _state = nextState;
      _message = error;
    });
  }

  Future<void> _resetRocket() async {
    _launchTimer?.cancel();
    final objectManager = _objectManager;
    final anchorManager = _anchorManager;
    final rocketNode = _rocketNode;
    final rocketAnchor = _rocketAnchor;
    if (objectManager == null && anchorManager == null) return;

    try {
      if (rocketNode != null) objectManager?.removeNode(rocketNode);
      final cn = _cloudNode;
      if (cn != null) objectManager?.removeNode(cn);
      for (final flame in _flameNodes) {
        objectManager?.removeNode(flame);
      }
      _flameNodes.clear();
      if (rocketAnchor != null) anchorManager?.removeAnchor(rocketAnchor);
    } catch (_) {
      // Ignore cleanup errors and return the UI to placement mode anyway.
    }

    await _countdownPlayer.stop();
    await _enginePlayer.stop();
    _engineAudioRunning = false;
    await _enginePlayer.setVolume(_engineBaseVolume);

    if (!mounted) return;

    setState(() {
      _rocketNode = null;
      _rocketAnchor = null;
      _cloudNode = null;
      _showPlacementUi = true;
      _cloudVisible = false;
      _flamesVisible = false;
      _launchPhase = LaunchPhase.idle;
      _launchElapsed = 0.0;
      _liftoffElapsed = 0.0;
      _launchOffset = 0.0;
      _countdownPlayed = false;
      _countdownCompleted = false;
      _liftoffTriggered = false;
      _engineStarted = false;
      _engineAudioRunning = false;
      if (_hasHorizontalPlane) {
        _state = ARPlacementState.readyToPlace;
        _message = 'Tap a horizontal surface to place the rocket.';
      } else {
        _state = ARPlacementState.scanning;
        _message = 'Move your phone slowly to detect a flat surface.';
      }
    });
    _sessionManager?.showPlanes(true);
  }

  // -------------------------------------------------------------------------
  // Launch animation
  // -------------------------------------------------------------------------

  void _startLaunchSequence() {
    _launchTimer?.cancel();
    setState(() {
      _launchPhase = LaunchPhase.idle;
      _launchElapsed = 0.0;
      _liftoffElapsed = 0.0;
      _launchOffset = 0.0;
      _countdownPlayed = false;
      _countdownCompleted = false;
      _liftoffTriggered = false;
      _engineStarted = false;
      _engineAudioRunning = false;
      _message = 'Rocket placed! Countdown starts in 1 second…';
    });
    const tickMs = 33;
    _launchTimer = Timer.periodic(
      const Duration(milliseconds: tickMs),
      (_) => _tickLaunch(tickMs / 1000.0),
    );
  }

  void _tickLaunch(double dt) {
    if (!mounted) return;
    _launchElapsed += dt;

    if (!_countdownPlayed && _launchElapsed >= _kIdleBeforeCountdownSeconds) {
      _countdownPlayed = true;
      setState(() {
        _message = '🔊 3... 2... 1...';
      });
      unawaited(_playCountdownAudio());
    }

    if (_launchPhase == LaunchPhase.idle) {
      _triggerLiftoffIfReady();
      return;
    }

    if (_launchPhase == LaunchPhase.lifting) {
      final liftElapsed = _launchElapsed - _liftoffElapsed;
      final rampT = (liftElapsed / _kAscentRampSeconds).clamp(0.0, 1.0);
      final speed =
          _kAscentInitialSpeedMps +
          (_kAscentCruiseSpeedMps - _kAscentInitialSpeedMps) * rampT;
      _launchOffset += speed * dt;

      final rn = _rocketNode;
      if (rn != null) {
        rn.position = Vector3(0.0, _launchOffset, 0.0);
      }
      if (_flamesVisible) {
        _updateFlameTransforms(_launchOffset);
      }

      if (!_cloudVisible && _launchOffset >= _kCloudLayerHeight * 0.6) {
        _showCloudLayer();
      }
    }
  }

  void _triggerLiftoffIfReady() {
    if (!mounted || _liftoffTriggered) return;
    if (!_countdownPlayed || !_countdownCompleted) return;

    _liftoffTriggered = true;
    _liftoffElapsed = _launchElapsed;

    setState(() {
      _launchPhase = LaunchPhase.lifting;
      _message = '🚀 Liftoff! Saturn V is launching!';
    });

    if (!_engineStarted) {
      _engineStarted = true;
      _showFlames();
      unawaited(_startEngineAudio());
    }
  }

  Future<void> _addCloudLayer(ARPlaneAnchor anchor) async {
    final om = _objectManager;
    if (om == null) return;
    final cloudNode = ARNode(
      type: NodeType.localGLTF2,
      uri: _cloudModelAssetPath,
      scale: Vector3.all(1.5 * _iosPluginModelScaleCompensation),
      position: Vector3(0.0, -10.0, 0.0),
      rotation: Vector4(0.0, 1.0, 0.0, 0.0),
    );
    final added = await om.addNode(cloudNode, planeAnchor: anchor);
    if (added ?? false) {
      _cloudNode = cloudNode;
    }
  }

  Future<void> _addEngineFlameNodes(ARPlaneAnchor anchor) async {
    final om = _objectManager;
    if (om == null) return;

    _flameNodes.clear();

    for (final offset in _engineOffsets) {
      final node = ARNode(
        type: NodeType.localGLTF2,
        uri: _flameSpriteModelAssetPath,
        scale: _flameScale,
        position: Vector3(offset.x, _kPlumeHiddenY, offset.z),
        rotation: Vector4(1.0, 0.0, 0.0, math.pi / 2),
      );

      final didAdd = await om.addNode(node, planeAnchor: anchor);
      if (didAdd ?? false) {
        _flameNodes.add(node);
      }
    }
  }

  Vector3 get _flameScale {
    final c = _iosPluginModelScaleCompensation;
    return Vector3(0.36 * c, 1.20 * c, 0.36 * c);
  }

  Vector3 _flameLocalPosition(Vector3 engineOffset, double rocketOffsetY) {
    return Vector3(
      engineOffset.x,
      _kEngineBaseY + rocketOffsetY,
      engineOffset.z,
    );
  }

  void _updateFlameTransforms(double rocketOffsetY) {
    final count = math.min(_flameNodes.length, _engineOffsets.length);
    for (var i = 0; i < count; i++) {
      _flameNodes[i].position = _flameLocalPosition(
        _engineOffsets[i],
        rocketOffsetY,
      );
    }
  }

  void _showFlames() {
    _flamesVisible = true;
    _updateFlameTransforms(_launchOffset);
  }

  Future<void> _playCountdownAudio() async {
    await _countdownPlayer.stop();
    _countdownCompleted = false;
    await _countdownPlayer.play(
      AssetSource('audio/countdown_liftoff.aiff'),
      volume: 1.0,
    );
  }

  Future<void> _startEngineAudio() async {
    if (_engineAudioRunning) {
      return;
    }
    _engineAudioRunning = true;
    await _enginePlayer.setReleaseMode(ReleaseMode.loop);
    await _enginePlayer.setVolume(_engineBaseVolume);
    await _enginePlayer.play(
      AssetSource('audio/rocket_engine_loop.wav'),
      volume: _engineBaseVolume,
    );
  }

  void _showCloudLayer() {
    final cn = _cloudNode;
    if (cn == null) return;
    _cloudVisible = true;
    cn.position = Vector3(0.0, _kCloudLayerHeight, 0.0);
  }

  Future<void> _handlePrimaryAction() async {
    if (_state == ARPlacementState.permissionBlocked) {
      await openAppSettings();
      return;
    }
    await _ensureCameraPermission();
  }

  void _setOverlayState(ARPlacementState state, String message) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _message = message;
    });
  }

  String? get _primaryActionLabel {
    switch (_state) {
      case ARPlacementState.permissionRequired:
        return 'Grant camera access';
      case ARPlacementState.permissionBlocked:
        return 'Open settings';
      case ARPlacementState.error:
        return _isCameraPermissionGranted ? null : 'Try again';
      default:
        return null;
    }
  }

  @override
  void dispose() {
    _launchTimer?.cancel();
    _countdownCompleteSub?.cancel();
    _engineStateSub?.cancel();
    unawaited(_countdownPlayer.dispose());
    unawaited(_enginePlayer.dispose());
    WidgetsBinding.instance.removeObserver(this);
    _sessionManager?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        automaticallyImplyLeading: false,
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
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Status / instruction overlay
                    ARStatusOverlay(
                      state: _state,
                      message: _message,
                      isHorizontalPlaneAvailable: _hasHorizontalPlane,
                      primaryActionLabel: _primaryActionLabel,
                      onPrimaryAction: _primaryActionLabel == null
                          ? null
                          : _handlePrimaryAction,
                      showReset: _rocketNode != null,
                      onReset: _resetRocket,
                      planeCount: _planeCount,
                      launchPhase: _launchPhase,
                    ),

                    const Spacer(),

                    // "Explore parts" button — visible only after placement.
                    if (_state == ARPlacementState.placed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ExplorePartsButton(onTap: _showPartsSheet),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Explore parts button
// ---------------------------------------------------------------------------

class _ExplorePartsButton extends StatelessWidget {
  const _ExplorePartsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        shape: const BeveledRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
      ),
      onPressed: onTap,
      icon: const Icon(Icons.rocket_launch_rounded),
      label: const Text(
        'EXPLORE ROCKET PARTS',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet: scrollable list of all parts
// ---------------------------------------------------------------------------

class RocketPartsSheet extends StatelessWidget {
  const RocketPartsSheet({
    super.key,
    required this.parts,
    required this.onPartSelected,
  });

  final List<RocketPart> parts;
  final ValueChanged<RocketPart> onPartSelected;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF060e15),
            border: Border(
              top: BorderSide(
                color: _primaryColor.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
          ),
          child: Column(
            children: [
              // Header row
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.rocket_launch_rounded,
                      color: _primaryColor,
                      shadows: [
                        BoxShadow(
                          color: _primaryColor.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'ROCKET SUB-SYSTEMS',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white54,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(color: _primaryColor, height: 1),
              // Parts list
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  itemCount: parts.length,
                  separatorBuilder: (_, s) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final part = parts[index];
                    return _PartListTile(
                      part: part,
                      onTap: () => onPartSelected(part),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PartListTile extends StatelessWidget {
  const _PartListTile({required this.part, required this.onTap});

  final RocketPart part;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: _primaryColor.withValues(alpha: 0.2),
      highlightColor: _primaryColor.withValues(alpha: 0.1),
      child: Ink(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: _primaryColor.withValues(alpha: 0.5),
              width: 2,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Text(part.emoji, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      part.name.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      part.shortDescription,
                      style: TextStyle(
                        color: _lightColor.withValues(alpha: 0.8),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: _primaryColor),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet: single part detail
// ---------------------------------------------------------------------------

class PartDetailSheet extends StatelessWidget {
  const PartDetailSheet({super.key, required this.part});

  final RocketPart part;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF060e15),
            border: Border(
              top: BorderSide(
                color: _primaryColor.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(part.emoji, style: const TextStyle(fontSize: 34)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            part.name.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 20,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            part.shortDescription,
                            style: const TextStyle(
                              color: _primaryColor,
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white54,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(color: _primaryColor, height: 1, thickness: 1),
              // Scrollable detail body
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPadding),
                  child: Text(
                    part.details,
                    style: TextStyle(
                      color: _lightColor.withValues(alpha: 0.9),
                      fontSize: 15,
                      height: 1.65,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Status overlay
// ---------------------------------------------------------------------------

class ARStatusOverlay extends StatelessWidget {
  const ARStatusOverlay({
    super.key,
    required this.state,
    required this.message,
    required this.isHorizontalPlaneAvailable,
    required this.primaryActionLabel,
    required this.onPrimaryAction,
    required this.showReset,
    required this.onReset,
    required this.planeCount,
    this.launchPhase = LaunchPhase.idle,
  });

  final ARPlacementState state;
  final String message;
  final bool isHorizontalPlaneAvailable;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool showReset;
  final VoidCallback onReset;
  final int planeCount;
  final LaunchPhase launchPhase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (state) {
      ARPlacementState.permissionRequired ||
      ARPlacementState.permissionBlocked => Icons.videocam_rounded,
      ARPlacementState.readyToPlace => Icons.touch_app_rounded,
      ARPlacementState.placed => Icons.rocket_launch_rounded,
      ARPlacementState.unsupported ||
      ARPlacementState.error => Icons.warning_amber_rounded,
      _ => Icons.view_in_ar_rounded,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: _backgroundColor.withValues(alpha: 0.8),
        border: Border.all(color: _primaryColor.withValues(alpha: 0.5)),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: _primaryColor,
                  shadows: [
                    BoxShadow(
                      color: _primaryColor.withValues(alpha: 0.5),
                      blurRadius: 8,
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _titleForState(state).toUpperCase(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: _lightColor),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _OverlayChip(label: _planeChipLabel, icon: _planeChipIcon),
                _OverlayChip(
                  label: showReset ? 'Rocket placed' : 'Single rocket mode',
                  icon: showReset
                      ? Icons.rocket_launch_rounded
                      : Icons.radio_button_checked_rounded,
                ),
                _OverlayChip(
                  label: planeCount == 0
                      ? 'No planes yet'
                      : '$planeCount plane${planeCount == 1 ? '' : 's'} tracked',
                  icon: Icons.layers_outlined,
                ),
                if (launchPhase != LaunchPhase.idle)
                  _OverlayChip(
                    label: launchPhase == LaunchPhase.lifting
                        ? '🚀 Launching…'
                        : '🌤 Cleared atmosphere',
                    icon: launchPhase == LaunchPhase.lifting
                        ? Icons.rocket_launch_rounded
                        : Icons.cloud_rounded,
                  ),
              ],
            ),
            if (primaryActionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                style: _buttonStyle,
                onPressed: onPrimaryAction,
                icon: Icon(
                  state == ARPlacementState.permissionBlocked
                      ? Icons.settings_rounded
                      : Icons.videocam_rounded,
                ),
                label: Text(primaryActionLabel!),
              ),
            ],
            if (showReset) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                style: _buttonStyle,
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('RESET ROCKET'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _planeChipLabel {
    switch (state) {
      case ARPlacementState.checkingPermission:
      case ARPlacementState.permissionRequired:
      case ARPlacementState.permissionBlocked:
        return 'Camera permission pending';
      case ARPlacementState.checkingSupport:
        return 'Opening AR camera';
      case ARPlacementState.initializing:
        return 'Preparing AR session';
      case ARPlacementState.unsupported:
      case ARPlacementState.error:
        return 'AR unavailable';
      case ARPlacementState.scanning:
      case ARPlacementState.readyToPlace:
      case ARPlacementState.placing:
      case ARPlacementState.placed:
        return isHorizontalPlaneAvailable
            ? 'Horizontal plane detected'
            : 'Scanning for horizontal plane';
    }
  }

  IconData get _planeChipIcon {
    switch (state) {
      case ARPlacementState.checkingPermission:
      case ARPlacementState.permissionRequired:
      case ARPlacementState.permissionBlocked:
        return Icons.videocam_outlined;
      case ARPlacementState.checkingSupport:
      case ARPlacementState.initializing:
        return Icons.view_in_ar_outlined;
      case ARPlacementState.unsupported:
      case ARPlacementState.error:
        return Icons.warning_amber_rounded;
      case ARPlacementState.scanning:
      case ARPlacementState.readyToPlace:
      case ARPlacementState.placing:
      case ARPlacementState.placed:
        return isHorizontalPlaneAvailable
            ? Icons.check_circle_outline_rounded
            : Icons.camera_alt_outlined;
    }
  }

  static String _titleForState(ARPlacementState state) {
    switch (state) {
      case ARPlacementState.checkingPermission:
        return 'Checking camera';
      case ARPlacementState.permissionRequired:
        return 'Camera required';
      case ARPlacementState.permissionBlocked:
        return 'Camera blocked';
      case ARPlacementState.checkingSupport:
        return 'Opening AR view';
      case ARPlacementState.initializing:
        return 'Initializing AR';
      case ARPlacementState.scanning:
        return 'Scanning surfaces';
      case ARPlacementState.readyToPlace:
        return 'Tap to place';
      case ARPlacementState.placing:
        return 'Placing rocket';
      case ARPlacementState.placed:
        return 'Rocket anchored';
      case ARPlacementState.unsupported:
        return 'AR unsupported';
      case ARPlacementState.error:
        return 'AR error';
    }
  }

  ButtonStyle get _buttonStyle => FilledButton.styleFrom(
    backgroundColor: _primaryColor,
    foregroundColor: Colors.black,
    textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1.1),
    shape: const BeveledRectangleBorder(
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(12),
        bottomRight: Radius.circular(12),
      ),
    ),
  );
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _primaryColor.withValues(alpha: 0.1),
        border: Border.all(color: _primaryColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: _lightColor),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
