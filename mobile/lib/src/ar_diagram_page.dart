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
import 'package:ar_flutter_plugin_2/models/hand_gesture_frame.dart';
import 'package:flutter/material.dart';
import 'package:genai/src/gesture_transform_math.dart';
import 'package:genai/src/hand_gesture_interpreter.dart';
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

  // Billboard rotation of each flashcard (parallel to _flashcardNodes).
  final List<Quaternion> _cardRotations = <Quaternion>[];

  // Precomputed pointer-line geometry (parallel to _pointerLineNodes).
  final List<_PointerLineGeometry> _lineGeometries = <_PointerLineGeometry>[];

  // Hand gesture controls
  bool _gestureModeEnabled = false;
  bool _gestureHintVisible = false;

  /// Set once `setHandTracking` has reported the device cannot do it (iOS < 14,
  /// MediaPipe model load failure, the historical `field platorm_ for s1.D`
  /// protobuf fault). Touch drag/zoom below is always live, so this only
  /// changes what the mode chip says.
  bool _handTrackingUnavailable = false;
  Timer? _gestureHintTimer;
  HandGestureInterpreter? _gestureInterpreter;
  final ValueNotifier<_HandOverlayModel> _handOverlay = ValueNotifier(
    const _HandOverlayModel(
      hands: [],
      landmarkSets: [],
      zooming: false,
      statusText: '',
    ),
  );

  // Touch drag/zoom
  double _touchScaleAtStart = _initialDiagramScale;

  // Diagram transform driven by gestures (anchor-local).
  // At 1.0 the rocket is 1.2 m tall (matching the label offsets); 0.5 spawns
  // it at a desk-friendly ~60 cm with everything scaled proportionally.
  static const double _initialDiagramScale = 0.5;
  Vector3 _diagramOffset = Vector3.zero();
  double _diagramScale = _initialDiagramScale;
  double _zoomScaleAtStart = _initialDiagramScale;
  static const double _minDiagramScale = 0.2;
  static const double _maxDiagramScale = 8.0;

  // Poses cached from the billboard polling timer, reused by drag math.
  Matrix4? _lastCameraPose;
  Matrix4? _lastAnchorPose;

  // -------------------------------------------------------------------
  // Scale helpers
  //
  // Android (patched plugin): a node's scale value is the rendered size in
  // meters of the model's largest dimension. iOS: values are raw-model
  // multipliers carrying the plugin's 0.01 GLTF factor (hence the ×100
  // compensation), which renders the same sizes for these assets.
  // -------------------------------------------------------------------

  /// Rocket height at _diagramScale = 1. The label offsets in _kLabelSpecs
  /// (pointer tips up to y = 1.02 m) are designed for this size.
  Vector3 get _rocketScale => Platform.isIOS
      ? Vector3.all(0.012 * _iosPluginModelScaleCompensation)
      : Vector3.all(1.2);

  /// Flashcards are 0.24 m wide at _diagramScale = 1.
  Vector3 get _cardScale => Platform.isIOS
      ? Vector3.all(_iosPluginModelScaleCompensation)
      : Vector3.all(0.24);

  /// Pointer line: [lineLength] long, 8 mm thick, at _diagramScale = 1.
  /// (dot.gltf is a ±1 cube, so on iOS a raw scale of l/2 spans l meters.)
  Vector3 _lineScale(double lineLength) => Platform.isIOS
      ? Vector3(
          lineLength * 0.5 * _iosPluginModelScaleCompensation,
          0.004 * _iosPluginModelScaleCompensation,
          0.004 * _iosPluginModelScaleCompensation,
        )
      : Vector3(lineLength, 0.008, 0.008);

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
      if (_rocketNode != null) {
        unawaited(_enableGestureMode());
      }
    } else if (state == AppLifecycleState.paused) {
      _disableGestureMode();
    }
  }

  @override
  void dispose() {
    _poseTimer?.cancel();
    _gestureHintTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_gestureModeEnabled) {
      _sessionManager?.setHandTracking(false);
    }
    _sessionManager?.dispose();
    _handOverlay.dispose();
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
    sessionManager.onHandGesture = _handleHandGestureFrame;

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
        scale: _rocketScale * _diagramScale,
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

      // Hand-gesture controls are on by default once the diagram is placed;
      // the hand icon in the app bar toggles them off.
      unawaited(_enableGestureMode());
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

    _lastCameraPose = pose;
    if (anchorPose != null) {
      _lastAnchorPose = anchorPose;
      await _updateBillboardsFromAnchorTransform(anchorPose);
    }
  }

  // -------------------------------------------------------------------
  // Hand gesture controls
  // -------------------------------------------------------------------

  Future<void> _toggleGestureMode() async {
    if (_gestureModeEnabled) {
      await _disableGestureMode();
      return;
    }
    await _enableGestureMode();
  }

  Future<void> _enableGestureMode() async {
    if (_gestureModeEnabled || !mounted) return;

    final sm = _sessionManager;
    if (sm == null) {
      debugPrint('HandGestures: cannot enable, session manager is null');
      return;
    }

    final size = MediaQuery.of(context).size;
    _gestureInterpreter = HandGestureInterpreter(
      viewAspect: size.height > 0 ? size.width / size.height : 16 / 9,
    );

    debugPrint('HandGestures: requesting setHandTracking(true)');
    final supported = await sm.setHandTracking(true);
    debugPrint('HandGestures: setHandTracking returned $supported');
    if (!mounted) return;
    if (!supported) {
      _gestureInterpreter = null;
      setState(() {
        _handTrackingUnavailable = true;
        _gestureHintVisible = true;
      });
      _flashGestureHint();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Hand gestures are unavailable on this device — drag and pinch '
            'with your fingers instead.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _gestureModeEnabled = true;
      _gestureHintVisible = true;
    });
    // Immediate feedback before the first detection tick arrives, so an
    // enabled-but-silent tracker is visibly distinguishable from "off".
    _handOverlay.value = const _HandOverlayModel(
      hands: [],
      landmarkSets: [],
      zooming: false,
      statusText: 'Hand tracking on — show a hand to the camera',
    );
    _flashGestureHint();
  }

  /// Shows the input-mode chip, then fades it out so it does not sit over the
  /// AR scene forever.
  void _flashGestureHint() {
    _gestureHintTimer?.cancel();
    _gestureHintTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _gestureHintVisible = false);
    });
  }

  Future<void> _disableGestureMode() async {
    if (!_gestureModeEnabled) return;
    _gestureHintTimer?.cancel();
    _gestureInterpreter = null;
    _handOverlay.value = const _HandOverlayModel(
      hands: [],
      landmarkSets: [],
      zooming: false,
      statusText: '',
    );
    if (mounted) {
      setState(() {
        _gestureModeEnabled = false;
        _gestureHintVisible = false;
      });
    } else {
      _gestureModeEnabled = false;
    }
    await _sessionManager?.setHandTracking(false);
  }

  void _handleHandGestureFrame(HandGestureFrame frame) {
    final interpreter = _gestureInterpreter;
    if (!_gestureModeEnabled || interpreter == null || !mounted) return;

    var zooming = _handOverlay.value.zooming;
    for (final command in interpreter.ingest(frame)) {
      switch (command) {
        case DragStart():
          break;
        case DragUpdate(:final delta):
          _applyDragDelta(delta);
        case DragEnd():
          break;
        case ZoomStart():
          _zoomScaleAtStart = _diagramScale;
          zooming = true;
        case ZoomUpdate(:final spanRatio):
          _diagramScale = (_zoomScaleAtStart * spanRatio).clamp(
            _minDiagramScale,
            _maxDiagramScale,
          );
          _applyDiagramTransform();
        case ZoomEnd():
          zooming = false;
      }
    }

    final ratios = frame.hands
        .map((h) => h.pinchRatio.toStringAsFixed(2))
        .join('  ');
    _handOverlay.value = _HandOverlayModel(
      hands: interpreter.indicators,
      landmarkSets: frame.hands.map((h) => h.landmarks).toList(),
      zooming: zooming,
      statusText: frame.hands.isEmpty
          ? 'No hands detected'
          : '${frame.hands.length} hand${frame.hands.length == 1 ? '' : 's'}  '
                'pinch: $ratios',
    );
  }

  // -------------------------------------------------------------------
  // Touch drag / zoom
  // -------------------------------------------------------------------

  void _onTouchScaleStart(ScaleStartDetails details) {
    _touchScaleAtStart = _diagramScale;
  }

  void _onTouchScaleUpdate(ScaleUpdateDetails details, Size viewSize) {
    if (details.scale != 1.0) {
      _diagramScale = (_touchScaleAtStart * details.scale).clamp(
        _minDiagramScale,
        _maxDiagramScale,
      );
    }
    final delta = details.focalPointDelta;
    if (delta != Offset.zero && viewSize.width > 0 && viewSize.height > 0) {
      _applyDragDelta(
        Offset(delta.dx / viewSize.width, delta.dy / viewSize.height),
      );
    } else {
      _applyDiagramTransform();
    }
  }

  /// Moves the diagram in the camera-facing plane at its current distance.
  void _applyDragDelta(Offset normDelta) {
    final cameraPose = _lastCameraPose;
    final anchorPose = _lastAnchorPose;
    if (cameraPose == null || anchorPose == null) return;

    final objectWorld =
        anchorPose.getTranslation() +
        anchorPose.getRotation().transformed(_diagramOffset);
    final distance = (objectWorld - cameraPose.getTranslation()).length.clamp(
      0.3,
      10.0,
    );

    _diagramOffset += computeAnchorLocalDelta(
      cameraPose: cameraPose,
      anchorPose: anchorPose,
      normDelta: normDelta,
      distance: distance,
    );
    _applyDiagramTransform();
  }

  /// Re-derives every node transform from [_diagramOffset] and
  /// [_diagramScale]. All 13 nodes are siblings under the anchor, so cards
  /// and pointer lines must be moved/scaled along with the rocket.
  void _applyDiagramTransform() {
    final rocketNode = _rocketNode;
    if (rocketNode == null) return;
    final scale = _diagramScale;

    rocketNode.transform = Matrix4.compose(
      _diagramOffset,
      Quaternion.identity(),
      _rocketScale * scale,
    );

    final cardCount = math.min(
      math.min(_flashcardNodes.length, _cardRotations.length),
      _labels.length,
    );
    for (var i = 0; i < cardCount; i++) {
      _flashcardNodes[i].transform = Matrix4.compose(
        _diagramOffset + _labels[i].labelOffset * scale,
        _cardRotations[i],
        _cardScale * scale,
      );
    }

    final lineCount = math.min(
      _pointerLineNodes.length,
      _lineGeometries.length,
    );
    for (var i = 0; i < lineCount; i++) {
      final geometry = _lineGeometries[i];
      _pointerLineNodes[i].transform = Matrix4.compose(
        _diagramOffset + geometry.center * scale,
        geometry.rotation,
        geometry.baseScale * scale,
      );
    }
  }

  // -------------------------------------------------------------------
  // Reset
  // -------------------------------------------------------------------

  Future<void> _reset() async {
    _poseTimer?.cancel();
    await _disableGestureMode();
    _diagramOffset = Vector3.zero();
    _diagramScale = _initialDiagramScale;
    _zoomScaleAtStart = _initialDiagramScale;
    _lastAnchorPose = null;
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
      _cardRotations.clear();
      _lineGeometries.clear();

      if (node != null) om?.removeNode(node);
      if (anchor != null) am?.removeAnchor(anchor);
    } catch (_) {
      // Ignore cleanup errors and return the UI to placement mode anyway.
    }

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
    _cardRotations.clear();
    _lineGeometries.clear();

    for (final label in _labels) {
      final cardNode = ARNode(
        type: NodeType.localGLTF2,
        uri: label.assetPath,
        scale: _cardScale * _diagramScale,
        position: label.labelOffset * _diagramScale,
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
      _cardRotations.add(Quaternion.identity());

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
        scale: _lineScale(lineLength) * _diagramScale,
        position: lineCenter * _diagramScale,
        rotation: lineRotation,
      );

      final didAddLine = await objectManager.addNode(
        lineNode,
        planeAnchor: anchor,
      );

      if (didAddLine ?? false) {
        _pointerLineNodes.add(lineNode);
        _lineGeometries.add(
          _PointerLineGeometry(
            center: lineCenter,
            rotation: _quaternionFromTo(Vector3(1.0, 0.0, 0.0), lineDirection),
            baseScale: _lineScale(lineLength),
          ),
        );
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

    final cameraPose = _lastCameraPose ?? await sessionManager.getCameraPose();
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

    final cardCount = math.min(
      math.min(_flashcardNodes.length, _cardRotations.length),
      _labels.length,
    );
    for (var index = 0; index < cardCount; index++) {
      final label = _labels[index];
      final cardNode = _flashcardNodes[index];
      final effectiveOffset =
          _diagramOffset + label.labelOffset * _diagramScale;
      final toCamera = cameraLocal - effectiveOffset;
      if (toCamera.length <= 0.0001) {
        continue;
      }

      final cardRotation = _quaternionFromTo(
        Vector3(0.0, 0.0, 1.0),
        toCamera.normalized(),
      );
      _cardRotations[index] = cardRotation;
      cardNode.transform = Matrix4.compose(
        effectiveOffset,
        cardRotation,
        _cardScale * _diagramScale,
      );
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
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Saturn V Diagram',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_state == _PlacementState.placed)
            IconButton(
              tooltip: _gestureModeEnabled
                  ? 'Disable hand gestures'
                  : 'Control with hand gestures',
              onPressed: _toggleGestureMode,
              icon: Icon(
                _gestureModeEnabled
                    ? Icons.back_hand
                    : Icons.back_hand_outlined,
                color: _gestureModeEnabled
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
              ),
            ),
        ],
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

          // Touch drag/zoom (once placed; taps are ignored after placement
          // anyway, so intercepting the AR view's touches is safe here).
          if (_state == _PlacementState.placed)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onTouchScaleStart,
                  onScaleUpdate: (details) =>
                      _onTouchScaleUpdate(details, constraints.biggest),
                ),
              ),
            ),

          // Hand gesture indicators
          if (_gestureModeEnabled)
            ValueListenableBuilder<_HandOverlayModel>(
              valueListenable: _handOverlay,
              builder: (context, model, _) => IgnorePointer(
                child: CustomPaint(
                  painter: _HandOverlayPainter(
                    model: model,
                    accentColor: Theme.of(context).colorScheme.primary,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),

          // Input-mode chip: says which of the two paths into
          // _applyDragDelta/_diagramScale is live.
          if (_gestureModeEnabled || _handTrackingUnavailable)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  // The chip is purely informational and sits above the touch
                  // GestureDetector; a faded-out AnimatedOpacity still hit
                  // tests, which would eat drags started near the bottom edge.
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _gestureHintVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 400),
                      child: _Chip(
                        label: _gestureModeEnabled
                            ? 'Hand gestures active · pinch to grab, two '
                                  'hands to zoom'
                            : 'Touch mode — hand tracking unavailable · drag '
                                  'to move, pinch to zoom',
                        icon: _gestureModeEnabled
                            ? Icons.back_hand_outlined
                            : Icons.touch_app_outlined,
                      ),
                    ),
                  ),
                ),
              ),
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

          if (_rocketNode != null)
            SafeArea(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: _FactRail(labels: _labels),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hand gesture overlay
// ---------------------------------------------------------------------------

/// Precomputed anchor-local geometry of a pointer line, captured at add time
/// so gesture transforms are pure arithmetic.
class _PointerLineGeometry {
  _PointerLineGeometry({
    required this.center,
    required this.rotation,
    required this.baseScale,
  });

  final Vector3 center;
  final Quaternion rotation;
  final Vector3 baseScale;
}

class _HandOverlayModel {
  const _HandOverlayModel({
    required this.hands,
    required this.landmarkSets,
    required this.zooming,
    required this.statusText,
  });

  final List<HandIndicator> hands;

  /// Raw 21-point landmark sets per detected hand (view-normalized), for
  /// verifying that hand tracking works and maps to the right screen spots.
  final List<List<Offset>> landmarkSets;
  final bool zooming;
  final String statusText;
}

/// Bone connections between MediaPipe hand-landmark indices.
const List<List<int>> _kHandConnections = [
  [0, 1], [1, 2], [2, 3], [3, 4], // thumb
  [0, 5], [5, 6], [6, 7], [7, 8], // index
  [5, 9], [9, 10], [10, 11], [11, 12], // middle
  [9, 13], [13, 14], [14, 15], [15, 16], // ring
  [13, 17], [17, 18], [18, 19], [19, 20], [0, 17], // pinky + palm
];

class _HandOverlayPainter extends CustomPainter {
  _HandOverlayPainter({required this.model, required this.accentColor});

  final _HandOverlayModel model;
  final Color accentColor;

  bool _valid(Offset p) => p.dx >= 0 && p.dy >= 0;

  void _paintLandmarks(Canvas canvas, Size size) {
    final bonePaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    final jointPaint = Paint()..color = Colors.greenAccent;
    final tipPaint = Paint()..color = Colors.orangeAccent;

    for (final landmarks in model.landmarkSets) {
      if (landmarks.length < 21) continue;
      final points = landmarks
          .map((p) => Offset(p.dx * size.width, p.dy * size.height))
          .toList();

      for (final bone in _kHandConnections) {
        final a = landmarks[bone[0]];
        final b = landmarks[bone[1]];
        if (_valid(a) && _valid(b)) {
          canvas.drawLine(points[bone[0]], points[bone[1]], bonePaint);
        }
      }
      for (var i = 0; i < 21; i++) {
        if (!_valid(landmarks[i])) continue;
        // Thumb tip (4) and index tip (8) drive the pinch — highlight them.
        final isPinchTip = i == 4 || i == 8;
        canvas.drawCircle(
          points[i],
          isPinchTip ? 6 : 3.5,
          isPinchTip ? tipPaint : jointPaint,
        );
      }
    }
  }

  void _paintStatusText(Canvas canvas, Size size) {
    if (model.statusText.isEmpty) return;
    final textPainter = TextPainter(
      text: TextSpan(
        text: model.statusText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 32);
    textPainter.paint(canvas, Offset(16, size.height - 40));
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintLandmarks(canvas, size);
    _paintStatusText(canvas, size);
    final centers = <Offset>[];
    for (final hand in model.hands) {
      centers.add(
        Offset(hand.position.dx * size.width, hand.position.dy * size.height),
      );
    }

    if (model.zooming && centers.length >= 2) {
      final linePaint = Paint()
        ..color = accentColor.withValues(alpha: 0.7)
        ..strokeWidth = 2;
      canvas.drawLine(centers[0], centers[1], linePaint);
    }

    for (var i = 0; i < centers.length; i++) {
      final hand = model.hands[i];
      final center = centers[i];
      if (hand.isPinching) {
        final glowPaint = Paint()
          ..color = accentColor.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
        canvas.drawCircle(center, 18, glowPaint);
        final fillPaint = Paint()..color = accentColor;
        canvas.drawCircle(center, 12, fillPaint);
      } else {
        final ringPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3;
        canvas.drawCircle(center, 16, ringPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandOverlayPainter oldDelegate) =>
      oldDelegate.model != model || oldDelegate.accentColor != accentColor;
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

class _FactRail extends StatelessWidget {
  const _FactRail({required this.labels});

  final List<_DiagramLabel> labels;

  @override
  Widget build(BuildContext context) {
    final maxRailWidth = MediaQuery.sizeOf(context).width * 0.46;
    final maxRailHeight = MediaQuery.sizeOf(context).height * 0.72;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.min(340, maxRailWidth)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rocket Fact Cards',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxRailHeight),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var index = 0; index < labels.length; index++)
                        _FactRailCard(
                          factNumber: index + 1,
                          title: labels[index].title,
                          description: labels[index].description,
                          color: labels[index].color,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FactRailCard extends StatelessWidget {
  const _FactRailCard({
    required this.factNumber,
    required this.title,
    required this.description,
    required this.color,
  });

  final int factNumber;
  final String title;
  final String description;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$factNumber',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFF171717),
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: const TextStyle(
                color: Color(0xFF212121),
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.28,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
