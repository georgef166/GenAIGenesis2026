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

const _backgroundColor = Color(0xFF05070B);
const _dotModelAssetPath = 'assets/models/dot.gltf';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Dot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F8CFF)),
        useMaterial3: true,
      ),
      home: const ARDotPage(),
    );
  }
}

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

class ARDotPage extends StatefulWidget {
  const ARDotPage({super.key});

  @override
  State<ARDotPage> createState() => _ARDotPageState();
}

class _ARDotPageState extends State<ARDotPage> with WidgetsBindingObserver {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;

  ARPlaneAnchor? _dotAnchor;
  ARNode? _dotNode;

  ARPlacementState _state = ARPlacementState.checkingPermission;
  String _message = 'Checking camera permission...';
  bool _isCameraPermissionGranted = false;
  bool _hasHorizontalPlane = false;
  bool _hasInitializedSession = false;
  bool _isConfiguringSession = false;
  int _planeCount = 0;

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

  Future<void> _ensureCameraPermission({bool requestIfNeeded = true}) async {
    _setOverlayState(
      ARPlacementState.checkingPermission,
      requestIfNeeded
          ? 'Checking camera permission...'
          : 'Refreshing camera permission...',
    );

    try {
      var status = await Permission.camera.status;
      if (!mounted) {
        return;
      }

      if (!status.isGranted && requestIfNeeded) {
        _setOverlayState(
          ARPlacementState.checkingPermission,
          'Requesting camera permission...',
        );
        status = await Permission.camera.request();
        if (!mounted) {
          return;
        }
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
      if (!mounted) {
        return;
      }

      _setOverlayState(
        ARPlacementState.error,
        'Failed to check camera permission: $error',
      );
    }
  }

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

      if (!mounted) {
        return;
      }

      setState(() {
        _hasInitializedSession = true;
        _isConfiguringSession = false;
        if (_dotNode != null) {
          _state = ARPlacementState.placed;
          _message = 'Dot placed. Use reset to place it somewhere else.';
        } else if (_hasHorizontalPlane) {
          _state = ARPlacementState.readyToPlace;
          _message = 'Tap a horizontal surface to place the dot.';
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
    if (!mounted) {
      return;
    }

    setState(() {
      _planeCount = planeCount;
      _hasHorizontalPlane = planeCount > 0;

      if (_dotNode != null ||
          _state == ARPlacementState.placing ||
          _state == ARPlacementState.permissionRequired ||
          _state == ARPlacementState.permissionBlocked ||
          _state == ARPlacementState.unsupported ||
          _state == ARPlacementState.error) {
        return;
      }

      if (_hasHorizontalPlane) {
        _state = ARPlacementState.readyToPlace;
        _message = 'Tap a horizontal surface to place the dot.';
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
    if (anchorManager == null ||
        objectManager == null ||
        !_hasInitializedSession ||
        !_hasHorizontalPlane ||
        _dotNode != null ||
        _state == ARPlacementState.placing) {
      return;
    }

    final hit = _firstPlaneHit(hitTestResults);
    if (hit == null) {
      _setOverlayState(
        ARPlacementState.readyToPlace,
        'Tap directly on a horizontal surface to place the dot.',
      );
      return;
    }

    _setOverlayState(ARPlacementState.placing, 'Placing the dot...');

    try {
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final didAddAnchor = await anchorManager.addAnchor(anchor) ?? false;
      if (!mounted) {
        return;
      }

      if (!didAddAnchor) {
        _setOverlayState(
          ARPlacementState.error,
          'Could not create an AR anchor at that position.',
        );
        return;
      }

      final node = ARNode(
        type: NodeType.localGLTF2,
        uri: _dotModelAssetPath,
        scale: Vector3(0.035, 0.035, 0.035),
        position: Vector3(0.0, 0.008, 0.0),
        rotation: Vector4(1.0, 0.0, 0.0, 0.0),
      );

      final didAddNode = await objectManager.addNode(node, planeAnchor: anchor);
      if (!mounted) {
        return;
      }

      if (!(didAddNode ?? false)) {
        anchorManager.removeAnchor(anchor);
        _setOverlayState(
          ARPlacementState.error,
          'Could not attach the dot model to that anchor.',
        );
        return;
      }

      setState(() {
        _dotAnchor = anchor;
        _dotNode = node;
        _state = ARPlacementState.placed;
        _message = 'Dot placed. Use reset to place it somewhere else.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      _setOverlayState(
        ARPlacementState.error,
        'Failed to place the dot: $error',
      );
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
        ? ARPlacementState.unsupported
        : ARPlacementState.error;

    setState(() {
      _isConfiguringSession = false;
      _state = nextState;
      _message = error;
    });
  }

  Future<void> _resetDot() async {
    final objectManager = _objectManager;
    final anchorManager = _anchorManager;
    final dotNode = _dotNode;
    final dotAnchor = _dotAnchor;
    if (objectManager == null && anchorManager == null) {
      return;
    }

    try {
      if (dotNode != null) {
        objectManager?.removeNode(dotNode);
      }
      if (dotAnchor != null) {
        anchorManager?.removeAnchor(dotAnchor);
      }
    } catch (_) {
      // Ignore cleanup errors and return the UI to placement mode anyway.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _dotNode = null;
      _dotAnchor = null;
      if (_hasHorizontalPlane) {
        _state = ARPlacementState.readyToPlace;
        _message = 'Tap a horizontal surface to place the dot.';
      } else {
        _state = ARPlacementState.scanning;
        _message = 'Move your phone slowly to detect a flat surface.';
      }
    });
  }

  Future<void> _handlePrimaryAction() async {
    if (_state == ARPlacementState.permissionBlocked) {
      await openAppSettings();
      return;
    }

    await _ensureCameraPermission();
  }

  void _setOverlayState(ARPlacementState state, String message) {
    if (!mounted) {
      return;
    }

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
      case ARPlacementState.checkingPermission:
      case ARPlacementState.checkingSupport:
      case ARPlacementState.initializing:
      case ARPlacementState.scanning:
      case ARPlacementState.readyToPlace:
      case ARPlacementState.placing:
      case ARPlacementState.placed:
      case ARPlacementState.unsupported:
        return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: _backgroundColor),
          if (_isCameraPermissionGranted)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topCenter,
                child: ARStatusOverlay(
                  state: _state,
                  message: _message,
                  isHorizontalPlaneAvailable: _hasHorizontalPlane,
                  primaryActionLabel: _primaryActionLabel,
                  onPrimaryAction: _primaryActionLabel == null
                      ? null
                      : _handlePrimaryAction,
                  showReset: _dotNode != null,
                  onReset: _resetDot,
                  planeCount: _planeCount,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  });

  final ARPlacementState state;
  final String message;
  final bool isHorizontalPlaneAvailable;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool showReset;
  final VoidCallback onReset;
  final int planeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final icon = switch (state) {
      ARPlacementState.permissionRequired ||
      ARPlacementState.permissionBlocked => Icons.videocam_rounded,
      ARPlacementState.readyToPlace => Icons.touch_app_rounded,
      ARPlacementState.placed => Icons.place_rounded,
      ARPlacementState.unsupported ||
      ARPlacementState.error => Icons.warning_amber_rounded,
      _ => Icons.view_in_ar_rounded,
    };

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
                    _titleForState(state),
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
                _OverlayChip(label: _planeChipLabel, icon: _planeChipIcon),
                _OverlayChip(
                  label: showReset ? 'Dot locked' : 'Single dot mode',
                  icon: showReset
                      ? Icons.lock_outline_rounded
                      : Icons.radio_button_checked_rounded,
                ),
                _OverlayChip(
                  label: planeCount == 0
                      ? 'No planes yet'
                      : '$planeCount plane${planeCount == 1 ? '' : 's'} tracked',
                  icon: Icons.layers_outlined,
                ),
              ],
            ),
            if (primaryActionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
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
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset dot'),
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
        return 'Placing dot';
      case ARPlacementState.placed:
        return 'Dot anchored';
      case ARPlacementState.unsupported:
        return 'AR unsupported';
      case ARPlacementState.error:
        return 'AR error';
    }
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
