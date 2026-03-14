import 'dart:io' show Platform;

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
import 'package:genai/rocket_parts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

// ---------------------------------------------------------------------------
// Asset path
// ---------------------------------------------------------------------------
const _rocketModelAssetPath = 'assets/models/saturn_v_-_nasa/scene.gltf';
const _iosPluginModelScaleCompensation = 100.0;

const _backgroundColor = Color(0xFF05070B);

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

  Vector3 get _rocketScale =>
      Platform.isIOS
          ? Vector3(0.2 * _iosPluginModelScaleCompensation,
              0.2 * _iosPluginModelScaleCompensation,
              0.2 * _iosPluginModelScaleCompensation)
          : Vector3(0.2, 0.2, 0.2);

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

      final didAddNode =
          await objectManager.addNode(node, planeAnchor: anchor);
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
        _message =
            'Rocket placed! Tap it or press "Explore parts" to learn about each section.';
      });
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
    final objectManager = _objectManager;
    final anchorManager = _anchorManager;
    final rocketNode = _rocketNode;
    final rocketAnchor = _rocketAnchor;
    if (objectManager == null && anchorManager == null) return;

    try {
      if (rocketNode != null) objectManager?.removeNode(rocketNode);
      if (rocketAnchor != null) anchorManager?.removeAnchor(rocketAnchor);
    } catch (_) {
      // Ignore cleanup errors and return the UI to placement mode anyway.
    }

    if (!mounted) return;

    setState(() {
      _rocketNode = null;
      _rocketAnchor = null;
      if (_hasHorizontalPlane) {
        _state = ARPlacementState.readyToPlace;
        _message = 'Tap a horizontal surface to place the rocket.';
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
    final colorScheme = Theme.of(context).colorScheme;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.primary,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onTap,
      icon: const Icon(Icons.rocket_launch_rounded),
      label: const Text(
        'Explore rocket parts',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0D1117),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header row
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.rocket_launch_rounded,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Rocket Parts',
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
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
              const Divider(color: Colors.white12, height: 1),
              // Parts list
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  itemCount: parts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
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
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
                      part.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      part.shortDescription,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colorScheme.primary),
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
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0D1117),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // Title row
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      part.emoji,
                      style: const TextStyle(fontSize: 34),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            part.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 20,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            part.shortDescription,
                            style: TextStyle(
                              color: colorScheme.primary,
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
              const Divider(color: Colors.white12, height: 1),
              // Scrollable detail body
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPadding),
                  child: Text(
                    part.details,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
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
      ARPlacementState.permissionBlocked =>
        Icons.videocam_rounded,
      ARPlacementState.readyToPlace => Icons.touch_app_rounded,
      ARPlacementState.placed => Icons.rocket_launch_rounded,
      ARPlacementState.unsupported ||
      ARPlacementState.error =>
        Icons.warning_amber_rounded,
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
                label: const Text('Reset rocket'),
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
