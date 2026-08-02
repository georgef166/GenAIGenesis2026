import 'dart:math' as math;

import 'package:ar_flutter_plugin_2/models/hand_gesture_frame.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'hand_gesture_interpreter.dart';

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

/// How far (logical px) a control may be from the cursor and still be grabbed
/// by the magnetic snap. The chip pairs on the prompt panel sit 8 px apart and
/// are ~110 px wide, so a radius wider than this starts stealing the neighbour.
const double kHandCursorSnapRadius = 60.0;

/// Cursor smoothing. Lower than the drag/zoom interpreter's 0.5 because at
/// ~15 Hz that is barely one frame of averaging — fine for grabbing a model,
/// visibly jittery for a pointer that has to land inside a 40 px chip.
/// 0.3 is a ~2.8-frame time constant (~190 ms of lag) which reads as "heavy
/// but responsive".
const double _kCursorSmoothingAlpha = 0.3;

/// The cursor holds its last position this long when detection blinks.
/// [HandGestureInterpreter.indicators] drops a hand the instant it is missed,
/// so without this the cursor strobes.
const int _kCursorHoldMs = 300;

/// Minimum gap between full render-tree sweeps.
const int _kSweepThrottleMs = 100;

/// A snap candidate may not cover more than this fraction of the page. The AR
/// pages put a full-screen `GestureDetector` under the UI for touch drag/zoom;
/// it is a `RenderPointerListener` like every button, but it is not a control.
const double _kMaxTargetAreaFraction = 0.25;

/// Reserved synthetic pointer id. Real ids are engine `pointerIdentifier`s,
/// monotonic from 1 — one per physical pointer-down for the process lifetime —
/// so this constant cannot collide in practice. A collision would overwrite a
/// real finger's hit-test entry and wedge whatever control it was on.
const int _kHandPointer = 0x7A11;

const Color _kCursorColor = Color(0xFF00ffff);
const Color _kSnapColor = Color(0xFF80ffde);

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Everything the hand overlay paints, recomputed once per tracking tick.
@immutable
class HandCursorModel {
  const HandCursorModel({
    this.cursor,
    this.pinchRatio = 1.0,
    this.pinching = false,
    this.snapRect,
    this.hands = const [],
    this.landmarkSets = const [],
    this.zooming = false,
    this.statusText = '',
    this.clickSeq = 0,
    this.clickAt,
  });

  static const HandCursorModel empty = HandCursorModel();

  /// Primary-hand cursor, view-normalized (0..1), or null when no hand has
  /// been seen recently.
  final Offset? cursor;

  /// Smoothed pinch ratio of the primary hand (~0.2 pinched, ~1.0 open).
  final double pinchRatio;
  final bool pinching;

  /// Snapped control, in coordinates local to the page's overlay root.
  final Rect? snapRect;

  /// All tracked hands, for the two-hand zoom line.
  final List<HandIndicator> hands;

  /// Raw 21-point landmark sets (view-normalized) — the skeleton debug draw.
  final List<List<Offset>> landmarkSets;
  final bool zooming;
  final String statusText;

  /// Incremented on every synthetic click; drives the ripple animation.
  final int clickSeq;

  /// Where the last click landed, local to the overlay root.
  final Offset? clickAt;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Turns hand-tracking ticks into a virtual cursor that magnetically snaps to
/// nearby controls and clicks them on a pinch.
///
/// It owns a second [HandGestureInterpreter] rather than sharing the page's:
/// the page's is tuned for grabbing a model and its state machine must not see
/// the frames that drive a click.
///
/// Mount [rootKey] on the page's `Stack`. Everything is expressed relative to
/// that box, so the overlay (a fill child of the same `Stack`) can paint the
/// model without any further conversion.
class HandCursorController extends ValueNotifier<HandCursorModel> {
  HandCursorController({
    required this.rootKey,
    this.snapRadius = kHandCursorSnapRadius,
  }) : _interpreter = HandGestureInterpreter(
         smoothingAlpha: _kCursorSmoothingAlpha,
       ),
       super(HandCursorModel.empty);

  final GlobalKey rootKey;
  final double snapRadius;
  final HandGestureInterpreter _interpreter;

  Offset? _heldCursor;
  bool _heldPinching = false;
  double _heldPinchRatio = 1.0;
  int _heldAtMs = 0;

  /// A click needs a rising edge *observed on one continuous hand*. Anything
  /// starting from unknown state — page start, [clear], a hand gone longer
  /// than the hold — stays disarmed until a hand is seen open, because the
  /// interpreter rebuilds a reappearing hand from scratch and its hysteresis
  /// latches straight back to pinching.
  bool _clickArmed = false;
  int _clickSeq = 0;

  List<(RenderPointerListener, Rect)> _targets = const [];
  int _sweptAtMs = -1 << 30;

  /// True while the cursor is over a control. The page uses this to keep its
  /// own drag/zoom interpreter out of the way: a pinch is a click *or* a grab,
  /// never both.
  bool get isSnapped => value.snapRect != null;

  void ingest(HandGestureFrame frame) {
    _interpreter.ingest(frame);
    final hands = _interpreter.indicators;
    // Two pinching hands is the page's existing zoom gesture — the cursor
    // defers to it and neither snaps nor clicks.
    final zooming = hands.where((h) => h.isPinching).length >= 2;

    Offset? cursor;
    var pinching = false;
    var pinchRatio = 1.0;
    if (hands.isNotEmpty) {
      final primary = hands.first;
      cursor = primary.position;
      pinching = primary.isPinching;
      pinchRatio = primary.pinchRatio;
      _heldCursor = cursor;
      _heldPinching = pinching;
      _heldPinchRatio = pinchRatio;
      _heldAtMs = frame.timestampMs;
    } else if (_heldCursor != null &&
        frame.timestampMs - _heldAtMs <= _kCursorHoldMs) {
      // The *pinch* is held along with the position, or a single missed
      // detection frame mid-pinch would re-arm the click and read as a second
      // press.
      cursor = _heldCursor;
      pinching = _heldPinching;
      pinchRatio = _heldPinchRatio;
    } else {
      _heldCursor = null;
      _heldPinching = false;
    }

    Rect? snapGlobal;
    Offset? probe;
    if (cursor != null && !zooming) {
      final point = _toGlobal(cursor);
      if (point != null) {
        final hit = _nearestTarget(point, frame.timestampMs);
        snapGlobal = hit?.$1;
        probe = hit?.$2;
      }
    }

    var clickAt = value.clickAt;
    if (probe != null && pinching && _clickArmed) {
      _click(probe);
      _clickSeq++;
      clickAt = _toLocal(probe);
    }
    _clickArmed = cursor != null && !pinching;

    value = HandCursorModel(
      cursor: cursor,
      pinchRatio: pinchRatio,
      pinching: pinching,
      snapRect: snapGlobal == null ? null : _toLocalRect(snapGlobal),
      hands: hands,
      landmarkSets: frame.hands.map((h) => h.landmarks).toList(),
      zooming: zooming,
      statusText: frame.hands.isEmpty
          ? 'No hands detected'
          : '${frame.hands.length} hand'
                '${frame.hands.length == 1 ? '' : 's'}  pinch: '
                '${frame.hands.map((h) => h.pinchRatio.toStringAsFixed(2)).join('  ')}',
      clickSeq: _clickSeq,
      clickAt: clickAt,
    );
  }

  /// Drops the cursor (tracking turned off, page paused, model reset).
  void clear() {
    // The interpreter too: its tracked hands keep both their stale positions
    // and their latched `isPinching`, so the cursor would otherwise fly in
    // from wherever it was when tracking stopped.
    _interpreter.reset();
    _heldCursor = null;
    _heldPinching = false;
    _clickArmed = false;
    _targets = const [];
    value = HandCursorModel.empty;
  }

  // -------------------------------------------------------------------
  // Geometry
  // -------------------------------------------------------------------

  RenderBox? get _root {
    final object = rootKey.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) return null;
    return object;
  }

  Offset? _toGlobal(Offset normalized) {
    final root = _root;
    if (root == null) return null;
    return root.localToGlobal(
      Offset(
        normalized.dx * root.size.width,
        normalized.dy * root.size.height,
      ),
    );
  }

  Offset _toLocal(Offset global) => _root?.globalToLocal(global) ?? global;

  Rect _toLocalRect(Rect global) {
    final root = _root;
    if (root == null) return global;
    return global.shift(-root.localToGlobal(Offset.zero));
  }

  // -------------------------------------------------------------------
  // Snap
  // -------------------------------------------------------------------

  /// Every interactive box under [root], as global rects. Generic on purpose —
  /// controls need no registration — but capped by area so the full-screen
  /// touch surface underneath the UI is not treated as a button.
  List<(RenderPointerListener, Rect)> _sweep(RenderBox root) {
    final maxArea =
        root.size.width * root.size.height * _kMaxTargetAreaFraction;
    final found = <(RenderPointerListener, Rect)>[];
    void visit(RenderObject object) {
      if (object is RenderPointerListener &&
          object.attached &&
          object.hasSize &&
          object.onPointerDown != null) {
        final rect = object.localToGlobal(Offset.zero) & object.size;
        if (rect.width * rect.height <= maxArea) found.add((object, rect));
      }
      object.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// The snapped control's rect and the point the click should be dispatched
  /// at, or null when nothing is in range.
  (Rect, Offset)? _nearestTarget(Offset point, int nowMs) {
    final root = _root;
    if (root == null) return null;
    if (nowMs - _sweptAtMs > _kSweepThrottleMs || nowMs < _sweptAtMs) {
      _targets = _sweep(root);
      _sweptAtMs = nowMs;
    }

    final ranked = <(double, RenderPointerListener, Rect)>[];
    for (final (object, rect) in _targets) {
      if (!object.attached) continue;
      final distance = _distanceToRect(point, rect);
      if (distance <= snapRadius) ranked.add((distance, object, rect));
    }
    ranked.sort((a, b) => a.$1.compareTo(b.$1));

    // One real hit test per survivor inherits IgnorePointer, z-order,
    // clipping, transforms and scroll clipping for free — far cheaper than
    // reimplementing any of it.
    //
    // Probe at the cursor clamped into the candidate, never at its centre: a
    // container that survives the area cap (the horizontal recents rail is
    // one) contains its own opaque listener, so probing its centre confirms
    // the container and the click then lands in the gap between two cards.
    // Clamping picks the deepest listener actually under the cursor, and
    // clicking at the same point guarantees highlight and click agree.
    for (final (_, object, rect) in ranked) {
      final probe = _clampInto(point, rect);
      if (_isTopmostAt(object, probe)) return (rect, probe);
    }
    return null;
  }

  /// [point] itself when inside [rect], otherwise the nearest point just
  /// inside its edge.
  static Offset _clampInto(Offset point, Rect rect) => Offset(
    point.dx.clamp(rect.left + 1, math.max(rect.left + 1, rect.right - 1)),
    point.dy.clamp(rect.top + 1, math.max(rect.top + 1, rect.bottom - 1)),
  );

  bool _isTopmostAt(RenderPointerListener object, Offset global) {
    final context = rootKey.currentContext;
    if (context == null) return false;
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      if (entry.target is RenderPointerListener) {
        return identical(entry.target, object);
      }
    }
    return false;
  }

  static double _distanceToRect(Offset point, Rect rect) {
    final dx = math.max(math.max(rect.left - point.dx, 0.0), point.dx - rect.right);
    final dy = math.max(math.max(rect.top - point.dy, 0.0), point.dy - rect.bottom);
    return math.sqrt(dx * dx + dy * dy);
  }

  // -------------------------------------------------------------------
  // Click
  // -------------------------------------------------------------------

  /// Down and up are dispatched back to back in one synchronous call, so there
  /// is no window in which a lost hand could leave a pointer stuck down —
  /// which would wedge the control against the next *real* finger.
  void _click(Offset global) {
    final context = rootKey.currentContext;
    if (context == null) return;
    final viewId = View.of(context).viewId;
    final timeStamp = Duration(
      microseconds: DateTime.now().microsecondsSinceEpoch,
    );
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        viewId: viewId,
        timeStamp: timeStamp,
        pointer: _kHandPointer,
        device: _kHandPointer,
        kind: PointerDeviceKind.touch,
        position: global,
        buttons: kPrimaryButton,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        viewId: viewId,
        timeStamp: timeStamp + const Duration(milliseconds: 40),
        pointer: _kHandPointer,
        device: _kHandPointer,
        kind: PointerDeviceKind.touch,
        position: global,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overlay
// ---------------------------------------------------------------------------

/// The cursor, the snap highlight and the click ripple. Always
/// `IgnorePointer`: an overlay that hit-tests while invisible eats the drags
/// meant for the AR view underneath.
class HandCursorOverlay extends StatefulWidget {
  const HandCursorOverlay({
    super.key,
    required this.controller,
    this.showSkeleton = false,
  });

  final HandCursorController controller;

  /// Draws the 21-point landmark skeleton and the detector status line. Useful
  /// for confirming tracking works; noise over a panel you are trying to click.
  final bool showSkeleton;

  @override
  State<HandCursorOverlay> createState() => _HandCursorOverlayState();
}

class _HandCursorOverlayState extends State<HandCursorOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  int _seenClickSeq = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onModelChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onModelChanged);
    _ripple.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    final seq = widget.controller.value.clickSeq;
    if (seq == _seenClickSeq) return;
    _seenClickSeq = seq;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _ripple.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final animationsOff = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.controller, _ripple]),
        builder: (context, _) {
          final model = widget.controller.value;
          return AnimatedOpacity(
            // The skeleton pass carries the detector status line, whose whole
            // job is to report "tracking on, seeing nothing" — fading it out
            // with the cursor would make that state pixel-identical to off.
            // The cursor and highlight self-skip when there is no cursor.
            opacity: model.cursor == null && !widget.showSkeleton ? 0.0 : 1.0,
            duration: animationsOff
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: CustomPaint(
              size: Size.infinite,
              painter: HandCursorPainter(
                model: model,
                showSkeleton: widget.showSkeleton,
                ripple: _ripple.isAnimating ? _ripple.value : null,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Bone connections between MediaPipe hand-landmark indices.
const List<List<int>> _kHandConnections = [
  [0, 1], [1, 2], [2, 3], [3, 4], // thumb
  [0, 5], [5, 6], [6, 7], [7, 8], // index
  [5, 9], [9, 10], [10, 11], [11, 12], // middle
  [9, 13], [13, 14], [14, 15], [15, 16], // ring
  [13, 17], [17, 18], [18, 19], [19, 20], [0, 17], // pinky + palm
];

class HandCursorPainter extends CustomPainter {
  HandCursorPainter({
    required this.model,
    this.showSkeleton = false,
    this.ripple,
  });

  final HandCursorModel model;
  final bool showSkeleton;

  /// 0..1 progress of the click ripple, or null when idle.
  final double? ripple;

  bool _valid(Offset p) => p.dx >= 0 && p.dy >= 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (showSkeleton) {
      _paintLandmarks(canvas, size);
      _paintStatusText(canvas, size);
    }
    _paintZoomLine(canvas, size);
    _paintSnapHighlight(canvas);
    _paintCursor(canvas, size);
    _paintRipple(canvas);
  }

  void _paintSnapHighlight(Canvas canvas) {
    final rect = model.snapRect;
    if (rect == null) return;
    final rrect = RRect.fromRectAndRadius(
      rect.inflate(4),
      const Radius.circular(10),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = _kSnapColor.withValues(alpha: 0.18),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = _kSnapColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  void _paintCursor(Canvas canvas, Size size) {
    final cursor = model.cursor;
    if (cursor == null) return;
    final center = Offset(cursor.dx * size.width, cursor.dy * size.height);

    // The ring contracts continuously as the fingers close, so "about to
    // click" is visible before the hysteresis threshold trips.
    final closure = (1.0 - ((model.pinchRatio - 0.38) / 0.62)).clamp(0.0, 1.0);
    final radius = 16.0 - 8.0 * closure;

    canvas.drawCircle(
      center,
      radius + 6,
      Paint()
        ..color = _kCursorColor.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    if (model.pinching) {
      canvas.drawCircle(center, radius, Paint()..color = _kCursorColor);
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawCircle(center, 2.5, Paint()..color = _kCursorColor);
    }
  }

  void _paintRipple(Canvas canvas) {
    final t = ripple;
    final at = model.clickAt;
    if (t == null || at == null) return;
    canvas.drawCircle(
      at,
      8 + 40 * t,
      Paint()
        ..color = _kCursorColor.withValues(alpha: (1 - t) * 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  void _paintZoomLine(Canvas canvas, Size size) {
    if (!model.zooming || model.hands.length < 2) return;
    Offset at(int i) => Offset(
      model.hands[i].position.dx * size.width,
      model.hands[i].position.dy * size.height,
    );
    canvas.drawLine(
      at(0),
      at(1),
      Paint()
        ..color = _kCursorColor.withValues(alpha: 0.7)
        ..strokeWidth = 2,
    );
  }

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
        if (_valid(landmarks[bone[0]]) && _valid(landmarks[bone[1]])) {
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
    final painter = TextPainter(
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
    painter.paint(canvas, Offset(16, size.height - 40));
  }

  @override
  bool shouldRepaint(covariant HandCursorPainter oldDelegate) =>
      oldDelegate.model != model ||
      oldDelegate.ripple != ripple ||
      oldDelegate.showSkeleton != showSkeleton;
}
