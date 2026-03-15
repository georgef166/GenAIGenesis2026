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
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

// ---------------------------------------------------------------------------
// Asset & constants
// ---------------------------------------------------------------------------

const _rocketModelAssetPath = 'assets/models/saturn_v_-_nasa/scene.gltf';

/// The plugin's iOS side applies a 0.01 multiplier to every child node loaded
/// from a GLTF asset.  Multiply the app-level scale by 100 on iOS to
/// compensate.
const _iosPluginModelScaleCompensation = 100.0;

const _backgroundColor = Color(0xFF05070B);

// ---------------------------------------------------------------------------
// Hardcoded label data
// ---------------------------------------------------------------------------

/// A single AR label card descriptor.
class _DiagramLabel {
  _DiagramLabel({
    required this.assetPath,
    required this.title,
    required this.description,
    required this.color,
    required this.labelOffset, // Position of the floating card (world-space offset from anchor)
    required this.pointerTarget, // World-space offset of the line's tip on the rocket
  });

  final String assetPath;
  final String title;
  final String description;
  final Color color;

  /// Offset from the rocket anchor origin where the card will float (metres).
  final Vector3 labelOffset;

  /// Offset from the rocket anchor origin where the pointer line ends (metres).
  final Vector3 pointerTarget;
}

class _DiagramLabelSpec {
  const _DiagramLabelSpec({
    required this.assetPath,
    required this.title,
    required this.description,
    required this.color,
    required this.cardOffset,
    required this.pointerTarget,
  });

  final String assetPath;
  final String title;
  final String description;
  final Color color;
  final Vector3 cardOffset;
  final Vector3 pointerTarget;
}

// ---------------------------------------------------------------------------
// Rocket proportions (rough world-space offsets in metres, Y-axis is up)
//
//  The Saturn V model is scaled to ~0.2 m on Android / 20 m on iOS before
//  the iOS plugin 0.01 compensation, so the *effective* rendered height is
//  ~0.2 m.  All offsets below are in un-compensated metres so they work the
//  same on both platforms.
//
//   Y=0          → ground / first-stage base
//   Y=+0.06      → between stage 1 and 2
//   Y=+0.10      → between stage 2 and 3
//   Y=+0.14      → upper body / lunar module housing
//   Y=+0.17      → service module
//   Y=+0.20      → command module tip
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Label data — cannot use const because Vector3 has no const constructor
// ---------------------------------------------------------------------------

final List<_DiagramLabelSpec> _kLabelSpecs = [
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/first_stage.gltf',
    title: 'First Stage',
    description:
        'Five F-1 engines producing nearly 7.7 million pounds of thrust. '
        'Burned for about 2.5 minutes and lifted the rocket to 38 miles altitude.',
    color: Color(0xFFFF6B35),
    cardOffset: Vector3(0.62, 0.14, 0.00),
    pointerTarget: Vector3(0.08, 0.06, 0.00),
  ),
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/second_stage.gltf',
    title: 'Second Stage',
    description:
        'Five J-2 engines burned for about 6 minutes and carried the rocket '
        'to roughly 115 miles altitude.',
    color: Color(0xFFFFB347),
    cardOffset: Vector3(0.62, 0.44, 0.00),
    pointerTarget: Vector3(0.08, 0.34, 0.00),
  ),
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/third_stage.gltf',
    title: 'Third Stage',
    description:
        'A single J-2 engine that boosted the spacecraft to about '
        '17,500 mph and sent it toward the Moon.',
    color: Color(0xFF4FC3F7),
    cardOffset: Vector3(0.62, 0.70, 0.00),
    pointerTarget: Vector3(0.08, 0.60, 0.00),
  ),
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/command_module_columbia.gltf',
    title: 'Command Module Columbia',
    description:
        'The living quarters for the astronauts and the only part of the '
        'spacecraft that returned to Earth.',
    color: Color(0xFFF48FB1),
    cardOffset: Vector3(0.62, 1.12, 0.00),
    pointerTarget: Vector3(0.08, 1.02, 0.00),
  ),
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/service_module.gltf',
    title: 'Service Module',
    description:
        'Housed the propulsion system used to steer the spacecraft, enter '
        'lunar orbit, and return to Earth.',
    color: Color(0xFFCE93D8),
    cardOffset: Vector3(0.62, 0.92, 0.00),
    pointerTarget: Vector3(0.08, 0.84, 0.00),
  ),
  _DiagramLabelSpec(
    assetPath: 'assets/models/flashcards/lunar_module.gltf',
    title: 'Lunar Module',
    description:
        'A two-stage spacecraft that carried astronauts from lunar orbit '
        "to the Moon's surface and back.",
    color: Color(0xFF81C784),
    cardOffset: Vector3(-0.62, 0.56, 0.00),
    pointerTarget: Vector3(-0.08, 0.56, 0.00),
  ),
];

List<_DiagramLabel> _buildDiagramLabels() {
  final labels = <_DiagramLabel>[];

  for (final spec in _kLabelSpecs) {
    labels.add(
      _DiagramLabel(
        assetPath: spec.assetPath,
        title: spec.title,
        description: spec.description,
        color: spec.color,
        labelOffset: spec.cardOffset,
        pointerTarget: spec.pointerTarget,
      ),
    );
  }

  return labels;
}

// ---------------------------------------------------------------------------
// Placement state
// ---------------------------------------------------------------------------

enum _PlacementState {
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
// Main page widget
// ---------------------------------------------------------------------------

class ARDiagramPage extends StatefulWidget {
  const ARDiagramPage({super.key});

  @override
  State<ARDiagramPage> createState() => _ARDiagramPageState();
}

class _ARDiagramPageState extends State<ARDiagramPage>
    with WidgetsBindingObserver {
  // AR managers
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;

  // Placed objects
  ARPlaneAnchor? _rocketAnchor;
  ARNode? _rocketNode;

  // State
  _PlacementState _state = _PlacementState.checkingPermission;
  String _message = 'Checking camera permission…';
  bool _isCameraPermissionGranted = false;
  bool _hasHorizontalPlane = false;
  bool _hasInitializedSession = false;
  bool _isConfiguringSession = false;
  int _planeCount = 0;
  bool _showPlacementUi = true;

  Timer? _poseTimer;
  late final List<_DiagramLabel> _labels = _buildDiagramLabels();
  final List<ARNode> _flashcardNodes = <ARNode>[];
  final List<ARNode> _pointerLineNodes = <ARNode>[];

  // -------------------------------------------------------------------
  // Scale helpers
  // -------------------------------------------------------------------

  double get _rocketScaleBase {
    return 0.012;
  }

  double get _iosModelCompensation =>
      Platform.isIOS ? _iosPluginModelScaleCompensation : 1.0;

  Vector3 get _rocketScale {
    final s = _rocketScaleBase * _iosModelCompensation;
    return Vector3(s, s, s);
  }

  Vector3 get _cardScale => Vector3.all(_iosModelCompensation);

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensureCameraPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureCameraPermission(requestIfNeeded: false);
    }
  }

  @override
  void dispose() {
    _poseTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sessionManager?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Permission
  // -------------------------------------------------------------------

  Future<void> _ensureCameraPermission({bool requestIfNeeded = true}) async {
    _setOverlay(
      _PlacementState.checkingPermission,
      requestIfNeeded
          ? 'Checking camera permission…'
          : 'Refreshing camera permission…',
    );

    try {
      var status = await Permission.camera.status;
      if (!mounted) return;

      if (!status.isGranted && requestIfNeeded) {
        _setOverlay(
          _PlacementState.checkingPermission,
          'Requesting camera permission…',
        );
        status = await Permission.camera.request();
        if (!mounted) return;
      }

      if (status.isGranted) {
        setState(() {
          _isCameraPermissionGranted = true;
          if (!_hasInitializedSession && !_isConfiguringSession) {
            _state = _PlacementState.checkingSupport;
            _message = 'Opening the AR camera…';
          }
        });
        return;
      }

      setState(() {
        _isCameraPermissionGranted = false;
        _hasInitializedSession = false;
      });

      if (status.isPermanentlyDenied) {
        _setOverlay(
          _PlacementState.permissionBlocked,
          'Camera access is blocked. Open settings to allow the app to use AR.',
        );
        return;
      }

      _setOverlay(
        _PlacementState.permissionRequired,
        'Camera access is required before the AR session can start.',
      );
    } catch (e) {
      if (!mounted) return;
      _setOverlay(
        _PlacementState.error,
        'Failed to check camera permission: $e',
      );
    }
  }

  // -------------------------------------------------------------------
  // AR callbacks
  // -------------------------------------------------------------------

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
    sessionManager.onPlaneOrPointTap = _handleTap;

    if (_isCameraPermissionGranted) {
      _initializeSession();
    }
  }

  void _initializeSession() {
    final sm = _sessionManager;
    final om = _objectManager;
    if (sm == null ||
        om == null ||
        !_isCameraPermissionGranted ||
        _hasInitializedSession ||
        _isConfiguringSession) {
      return;
    }

    _isConfiguringSession = true;
    _setOverlay(_PlacementState.initializing, 'Initializing the AR session…');

    try {
      sm.onInitialize(
        showAnimatedGuide: true,
        showFeaturePoints: false,
        showPlanes: true,
        showWorldOrigin: false,
        handleTaps: true,
        handlePans: false,
        handleRotation: false,
      );
      om.onInitialize();

      if (!mounted) return;

      setState(() {
        _hasInitializedSession = true;
        _isConfiguringSession = false;
        if (_rocketNode != null) {
          _state = _PlacementState.placed;
          _message = 'Rocket placed. Move around to explore the labels.';
        } else if (_hasHorizontalPlane) {
          _state = _PlacementState.readyToPlace;
          _message = 'Tap a surface to place the Saturn V diagram.';
        } else {
          _state = _PlacementState.scanning;
          _message = 'Move your phone slowly to detect a flat surface.';
        }
      });
    } catch (e) {
      _isConfiguringSession = false;
      _handleSessionError('Failed to start AR: $e');
    }
  }

  void _handlePlaneDetected(int count) {
    if (!mounted) return;
    setState(() {
      _planeCount = count;
      _hasHorizontalPlane = count > 0;
      if (_rocketNode != null ||
          _state == _PlacementState.placing ||
          _state == _PlacementState.permissionRequired ||
          _state == _PlacementState.permissionBlocked ||
          _state == _PlacementState.unsupported ||
          _state == _PlacementState.error) {
        return;
      }
      if (_hasHorizontalPlane) {
        _state = _PlacementState.readyToPlace;
        _message = 'Tap a surface to place the Saturn V diagram.';
      } else if (_hasInitializedSession) {
        _state = _PlacementState.scanning;
        _message = 'Move your phone slowly to detect a flat surface.';
      }
    });
  }

  Future<void> _handleTap(List<ARHitTestResult> hits) async {
    // Once placed, ignore taps.
    if (_rocketNode != null) return;

    final am = _anchorManager;
    final om = _objectManager;
    if (am == null ||
        om == null ||
        !_hasInitializedSession ||
        !_hasHorizontalPlane ||
        _state == _PlacementState.placing) {
      return;
    }

    final hit = _firstPlaneHit(hits);
    if (hit == null) {
      _setOverlay(
        _PlacementState.readyToPlace,
        'Tap directly on a horizontal surface.',
      );
      return;
    }

    _setOverlay(_PlacementState.placing, 'Placing the rocket diagram…');

    try {
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final didAddAnchor = await am.addAnchor(anchor) ?? false;
      if (!mounted) return;

      if (!didAddAnchor) {
        _setOverlay(
          _PlacementState.error,
          'Could not create an AR anchor at that position.',
        );
        return;
      }

      final node = ARNode(
        type: NodeType.localGLTF2,
        uri: _rocketModelAssetPath,
        scale: _rocketScale,
        position: Vector3(0.0, 0.0, 0.0),
        rotation: Vector4(1.0, 0.0, 0.0, 0.0),
      );

      final didAdd = await om.addNode(node, planeAnchor: anchor);
      if (!mounted) return;

      if (!(didAdd ?? false)) {
        am.removeAnchor(anchor);
        _setOverlay(
          _PlacementState.error,
          'Could not attach the rocket model to that anchor.',
        );
        return;
      }

      // Store the anchor world transform from the hit result so we can use it
      // immediately for the label overlay before the first camera poll fires.
      final anchorTransform = Matrix4.fromFloat64List(
        hit.worldTransform.storage,
      );

      setState(() {
        _rocketAnchor = anchor;
        _rocketNode = node;
        _state = _PlacementState.placed;
        _showPlacementUi = false;
        _message = 'Saturn V placed! Walk around to explore the labels.';
      });
      _sessionManager?.showPlanes(false);

      final addedCards = await _addFlashcardsAndPointers(anchor);
      if (!mounted) return;

      if (!addedCards) {
        _setOverlay(
          _PlacementState.error,
          'Rocket placed, but flashcards failed to load. Reset and try again.',
        );
        return;
      }

      // Store once to seed billboard updates immediately.
      await _updateBillboardsFromAnchorTransform(anchorTransform);

      // Start polling camera pose every ~33 ms (≈30 fps).
      _startPosePolling();
    } catch (e) {
      if (!mounted) return;
      _setOverlay(_PlacementState.error, 'Failed to place the rocket: $e');
    }
  }

  void _startPosePolling() {
    _poseTimer?.cancel();
    _poseTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _updateCameraPose(),
    );
  }

  Future<void> _updateCameraPose() async {
    if (!mounted || _sessionManager == null) return;
    final pose = await _sessionManager!.getCameraPose();
    if (!mounted) return;
    if (pose == null) return;

    Matrix4? anchorPose;
    final rocketAnchor = _rocketAnchor;
    if (rocketAnchor != null) {
      anchorPose = await _sessionManager!.getPose(rocketAnchor);
      if (!mounted) return;
    }

    if (anchorPose != null) {
      await _updateBillboardsFromAnchorTransform(anchorPose);
    }
  }

  // -------------------------------------------------------------------
  // Reset
  // -------------------------------------------------------------------

  Future<void> _reset() async {
    _poseTimer?.cancel();
    final om = _objectManager;
    final am = _anchorManager;
    final node = _rocketNode;
    final anchor = _rocketAnchor;

    try {
      for (final lineNode in _pointerLineNodes) {
        om?.removeNode(lineNode);
      }
      _pointerLineNodes.clear();

      for (final cardNode in _flashcardNodes) {
        om?.removeNode(cardNode);
      }
      _flashcardNodes.clear();

      if (node != null) om?.removeNode(node);
      if (anchor != null) am?.removeAnchor(anchor);
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _rocketNode = null;
      _rocketAnchor = null;
      _showPlacementUi = true;
      _state = _hasHorizontalPlane
          ? _PlacementState.readyToPlace
          : _PlacementState.scanning;
      _message = _hasHorizontalPlane
          ? 'Tap a surface to place the Saturn V diagram.'
          : 'Move your phone slowly to detect a flat surface.';
    });
    _sessionManager?.showPlanes(true);
  }

  Future<bool> _addFlashcardsAndPointers(ARPlaneAnchor anchor) async {
    final objectManager = _objectManager;
    if (objectManager == null) {
      return false;
    }

    _flashcardNodes.clear();
    _pointerLineNodes.clear();

    for (final label in _labels) {
      final cardNode = ARNode(
        type: NodeType.localGLTF2,
        uri: label.assetPath,
        scale: _cardScale,
        position: label.labelOffset,
        rotation: Vector4(0.0, 1.0, 0.0, 0.0),
      );

      final didAddCard = await objectManager.addNode(
        cardNode,
        planeAnchor: anchor,
      );

      if (!(didAddCard ?? false)) {
        continue;
      }

      _flashcardNodes.add(cardNode);

      final lineVector = label.pointerTarget - label.labelOffset;
      final lineLength = lineVector.length;
      if (lineLength <= 0.0001) {
        continue;
      }

      final lineCenter = label.labelOffset + (lineVector * 0.5);
      final lineDirection = lineVector.normalized();
      final lineRotation = _axisAngleFromTo(
        Vector3(1.0, 0.0, 0.0),
        lineDirection,
      );

      final lineNode = ARNode(
        type: NodeType.localGLTF2,
        uri: 'assets/models/dot.gltf',
        scale: Vector3(
          (lineLength * 0.5) * _iosModelCompensation,
          0.004 * _iosModelCompensation,
          0.004 * _iosModelCompensation,
        ),
        position: lineCenter,
        rotation: lineRotation,
      );

      final didAddLine = await objectManager.addNode(
        lineNode,
        planeAnchor: anchor,
      );

      if (didAddLine ?? false) {
        _pointerLineNodes.add(lineNode);
      }
    }

    return _flashcardNodes.isNotEmpty;
  }

  Future<void> _updateBillboardsFromAnchorTransform(Matrix4 anchorWorld) async {
    if (_flashcardNodes.isEmpty) {
      return;
    }

    final sessionManager = _sessionManager;
    if (sessionManager == null) {
      return;
    }

    final cameraPose = await sessionManager.getCameraPose();
    if (cameraPose == null || !mounted) {
      return;
    }

    final cameraWorld = cameraPose.getTranslation();
    final anchorInverse = Matrix4.inverted(anchorWorld);
    final cameraLocalV4 = anchorInverse.transform(
      Vector4(cameraWorld.x, cameraWorld.y, cameraWorld.z, 1.0),
    );
    final cameraLocal = Vector3(
      cameraLocalV4.x,
      cameraLocalV4.y,
      cameraLocalV4.z,
    );

    for (var index = 0; index < _flashcardNodes.length; index++) {
      final label = _labels[index];
      final cardNode = _flashcardNodes[index];
      final toCamera = cameraLocal - label.labelOffset;
      if (toCamera.length <= 0.0001) {
        continue;
      }

      final cardRotation = _quaternionFromTo(
        Vector3(0.0, 0.0, 1.0),
        toCamera.normalized(),
      );
      cardNode.rotationFromQuaternion = cardRotation;
    }
  }

  Vector4 _axisAngleFromTo(Vector3 from, Vector3 to) {
    final q = _quaternionFromTo(from, to);
    final safeW = q.w.clamp(-1.0, 1.0);
    final angle = 2.0 * math.acos(safeW);
    final s = math.sqrt(math.max(0.0, 1.0 - safeW * safeW));

    if (s < 0.0001) {
      return Vector4(0.0, 1.0, 0.0, 0.0);
    }

    return Vector4(q.x / s, q.y / s, q.z / s, angle);
  }

  Quaternion _quaternionFromTo(Vector3 from, Vector3 to) {
    final a = from.normalized();
    final b = to.normalized();
    final dot = a.dot(b);

    if (dot > 0.9999) {
      return Quaternion.identity();
    }

    if (dot < -0.9999) {
      final orthogonal = (a.cross(Vector3(1.0, 0.0, 0.0)).length > 0.0001)
          ? a.cross(Vector3(1.0, 0.0, 0.0)).normalized()
          : a.cross(Vector3(0.0, 1.0, 0.0)).normalized();
      return Quaternion.axisAngle(orthogonal, math.pi);
    }

    final axis = a.cross(b);
    final s = math.sqrt((1.0 + dot) * 2.0);
    final invS = 1.0 / s;

    return Quaternion(
      axis.x * invS,
      axis.y * invS,
      axis.z * invS,
      s * 0.5,
    ).normalized();
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  ARHitTestResult? _firstPlaneHit(List<ARHitTestResult> hits) {
    for (final h in hits) {
      if (h.type == ARHitTestResultType.plane) return h;
    }
    return null;
  }

  void _handleSessionError(String error) {
    if (!mounted) return;
    final lower = error.toLowerCase();
    final next =
        lower.contains('not supported') ||
            lower.contains('unsupported') ||
            lower.contains('arcore') ||
            lower.contains('arkit')
        ? _PlacementState.unsupported
        : _PlacementState.error;
    setState(() {
      _isConfiguringSession = false;
      _state = next;
      _message = error;
    });
  }

  Future<void> _handlePrimaryAction() async {
    if (_state == _PlacementState.permissionBlocked) {
      await openAppSettings();
      return;
    }
    await _ensureCameraPermission();
  }

  void _setOverlay(_PlacementState s, String msg) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _message = msg;
    });
  }

  String? get _primaryActionLabel {
    switch (_state) {
      case _PlacementState.permissionRequired:
        return 'Grant camera access';
      case _PlacementState.permissionBlocked:
        return 'Open settings';
      case _PlacementState.error:
        return _isCameraPermissionGranted ? null : 'Try again';
      default:
        return null;
    }
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Saturn V Diagram',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background colour (shown while AR isn't ready)
          const ColoredBox(color: _backgroundColor),

          // AR scene
          if (_isCameraPermissionGranted)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),

          // HUD
          if (_showPlacementUi)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _StatusCard(
                      state: _state,
                      message: _message,
                      planeCount: _planeCount,
                      isPlaneAvailable: _hasHorizontalPlane,
                      showReset: _rocketNode != null,
                      primaryActionLabel: _primaryActionLabel,
                      onPrimaryAction: _primaryActionLabel == null
                          ? null
                          : _handlePrimaryAction,
                      onReset: _reset,
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
// Status HUD card (simplified version for the diagram page)
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.state,
    required this.message,
    required this.planeCount,
    required this.isPlaneAvailable,
    required this.showReset,
    required this.primaryActionLabel,
    required this.onPrimaryAction,
    required this.onReset,
  });

  final _PlacementState state;
  final String message;
  final int planeCount;
  final bool isPlaneAvailable;
  final bool showReset;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final VoidCallback onReset;

  static String _title(_PlacementState s) => switch (s) {
    _PlacementState.checkingPermission => 'Checking camera',
    _PlacementState.permissionRequired => 'Camera required',
    _PlacementState.permissionBlocked => 'Camera blocked',
    _PlacementState.checkingSupport => 'Opening AR view',
    _PlacementState.initializing => 'Initializing AR',
    _PlacementState.scanning => 'Scanning surfaces',
    _PlacementState.readyToPlace => 'Tap to place',
    _PlacementState.placing => 'Placing diagram',
    _PlacementState.placed => 'Diagram anchored',
    _PlacementState.unsupported => 'AR unsupported',
    _PlacementState.error => 'AR error',
  };

  static IconData _icon(_PlacementState s) => switch (s) {
    _PlacementState.permissionRequired ||
    _PlacementState.permissionBlocked => Icons.videocam_rounded,
    _PlacementState.readyToPlace => Icons.touch_app_rounded,
    _PlacementState.placed => Icons.schema_rounded,
    _PlacementState.unsupported ||
    _PlacementState.error => Icons.warning_amber_rounded,
    _ => Icons.view_in_ar_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                Icon(_icon(state), color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _title(state),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 10),
            // Plane count chip
            _Chip(
              label: planeCount == 0
                  ? 'Scanning for surfaces…'
                  : '$planeCount surface${planeCount == 1 ? '' : 's'} detected',
              icon: planeCount > 0
                  ? Icons.check_circle_outline_rounded
                  : Icons.camera_alt_outlined,
            ),
            if (primaryActionLabel != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onPrimaryAction,
                icon: const Icon(Icons.videocam_rounded),
                label: Text(primaryActionLabel!),
              ),
            ],
            if (showReset) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset diagram'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon});
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
            Icon(icon, size: 15, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
