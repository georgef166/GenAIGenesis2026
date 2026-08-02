import 'dart:ui' show Offset;

import 'package:ar_flutter_plugin_2/models/hand_gesture_frame.dart';

/// A hand indicator for the on-screen overlay.
class HandIndicator {
  HandIndicator({required this.position, required this.isPinching});

  /// View-normalized position (0..1).
  final Offset position;
  final bool isPinching;
}

/// Commands emitted by [HandGestureInterpreter].
sealed class GestureCommand {}

class DragStart extends GestureCommand {
  DragStart(this.at);
  final Offset at;
}

class DragUpdate extends GestureCommand {
  DragUpdate(this.delta, this.at);

  /// View-normalized delta since the previous update.
  final Offset delta;
  final Offset at;
}

class DragEnd extends GestureCommand {}

class ZoomStart extends GestureCommand {
  ZoomStart(this.span);

  /// Aspect-corrected distance between the two pinch points at zoom start.
  final double span;
}

class ZoomUpdate extends GestureCommand {
  ZoomUpdate(this.spanRatio);

  /// Current span divided by the span at [ZoomStart].
  final double spanRatio;
}

class ZoomEnd extends GestureCommand {}

enum _GestureState { idle, dragging, zooming }

class _SmoothedHand {
  _SmoothedHand(TrackedHand hand)
      : x = hand.cx,
        y = hand.cy,
        pinchRatio = hand.pinchRatio;

  double x;
  double y;
  double pinchRatio;
  bool isPinching = false;

  Offset get position => Offset(x, y);

  void update(TrackedHand hand, double alpha) {
    x = x + alpha * (hand.cx - x);
    y = y + alpha * (hand.cy - y);
    pinchRatio = pinchRatio + alpha * (hand.pinchRatio - pinchRatio);
  }
}

/// Turns raw per-tick hand observations into drag/zoom commands.
///
/// State machine: idle -> dragging (exactly one pinching hand) -> zooming
/// (two pinching hands). Pinch detection uses hysteresis ([pinchOn]/[pinchOff])
/// on the smoothed pinch ratio; a grace period keeps the current gesture alive
/// through brief detection dropouts.
class HandGestureInterpreter {
  HandGestureInterpreter({
    this.pinchOn = 0.38,
    this.pinchOff = 0.55,
    this.smoothingAlpha = 0.5,
    this.graceMs = 180,
    this.minConfidence = 0.5,
    this.viewAspect = 16 / 9,
  });

  /// A hand starts pinching when its smoothed ratio drops below this.
  final double pinchOn;

  /// A pinching hand releases when its smoothed ratio rises above this.
  final double pinchOff;

  /// EMA coefficient applied to positions and pinch ratios (1 = no smoothing).
  final double smoothingAlpha;

  /// How long a gesture survives without a supporting pinching hand.
  final int graceMs;

  /// Hands below this confidence are ignored.
  final double minConfidence;

  /// Width/height of the AR view; x distances are multiplied by this so
  /// two-hand spans are isotropic.
  final double viewAspect;

  _GestureState _state = _GestureState.idle;
  final List<_SmoothedHand> _hands = [];
  int? _lastSupportedTimestampMs;
  Offset? _dragPoint;
  double? _zoomStartSpan;

  /// Latest smoothed hands, for overlay rendering.
  List<HandIndicator> get indicators => _hands
      .map((h) => HandIndicator(position: h.position, isPinching: h.isPinching))
      .toList();

  /// Ingests one tick and returns the commands it produces (possibly empty).
  List<GestureCommand> ingest(HandGestureFrame frame) {
    final observed = frame.hands
        .where((h) => h.confidence >= minConfidence)
        .take(2)
        .toList();
    _associate(observed);

    final pinching = _hands.where((h) => h.isPinching).toList();
    final commands = <GestureCommand>[];

    final requiredHands = switch (_state) {
      _GestureState.idle => 0,
      _GestureState.dragging => 1,
      _GestureState.zooming => 2,
    };
    if (pinching.length >= requiredHands) {
      _lastSupportedTimestampMs = frame.timestampMs;
    } else if (_hands.length < requiredHands) {
      // Supporting hands vanished from detection (dropout), as opposed to a
      // visible hand deliberately releasing its pinch: hold the gesture
      // through the grace period.
      final last = _lastSupportedTimestampMs ?? frame.timestampMs;
      if (frame.timestampMs - last <= graceMs) {
        return commands;
      }
    }

    switch (_state) {
      case _GestureState.idle:
        if (pinching.length >= 2) {
          _startZoom(pinching, commands);
        } else if (pinching.length == 1) {
          _startDrag(pinching.first, commands);
        }
      case _GestureState.dragging:
        if (pinching.length >= 2) {
          commands.add(DragEnd());
          _startZoom(pinching, commands);
        } else if (pinching.length == 1) {
          final at = pinching.first.position;
          final delta = at - _dragPoint!;
          _dragPoint = at;
          if (delta != Offset.zero) {
            commands.add(DragUpdate(delta, at));
          }
        } else {
          commands.add(DragEnd());
          _toIdle();
        }
      case _GestureState.zooming:
        if (pinching.length >= 2) {
          final span = _span(pinching[0], pinching[1]);
          commands.add(ZoomUpdate(span / _zoomStartSpan!));
        } else {
          commands.add(ZoomEnd());
          if (pinching.length == 1) {
            _startDrag(pinching.first, commands);
          } else {
            _toIdle();
          }
        }
    }
    return commands;
  }

  void _startDrag(_SmoothedHand hand, List<GestureCommand> commands) {
    _state = _GestureState.dragging;
    _dragPoint = hand.position;
    _zoomStartSpan = null;
    commands.add(DragStart(hand.position));
  }

  void _startZoom(List<_SmoothedHand> pinching, List<GestureCommand> commands) {
    _state = _GestureState.zooming;
    _zoomStartSpan = _span(pinching[0], pinching[1]);
    _dragPoint = null;
    commands.add(ZoomStart(_zoomStartSpan!));
  }

  void _toIdle() {
    _state = _GestureState.idle;
    _dragPoint = null;
    _zoomStartSpan = null;
  }

  double _span(_SmoothedHand a, _SmoothedHand b) {
    final dx = (a.x - b.x) * viewAspect;
    final dy = a.y - b.y;
    final span = Offset(dx, dy).distance;
    return span < 1e-6 ? 1e-6 : span;
  }

  /// Matches observed hands to tracked hands by nearest neighbor, updating
  /// smoothed values and pinch hysteresis in place.
  void _associate(List<TrackedHand> observed) {
    final unmatched = List<TrackedHand>.from(observed);
    final matched = <_SmoothedHand>{};

    // Greedy nearest-neighbor pairing (at most 2 hands, so this is exact
    // enough in practice and stable when hands cross).
    while (unmatched.isNotEmpty && matched.length < _hands.length) {
      _SmoothedHand? bestTracked;
      TrackedHand? bestObserved;
      var bestDist = double.infinity;
      for (final tracked in _hands) {
        if (matched.contains(tracked)) continue;
        for (final obs in unmatched) {
          final d = (tracked.position - Offset(obs.cx, obs.cy)).distanceSquared;
          if (d < bestDist) {
            bestDist = d;
            bestTracked = tracked;
            bestObserved = obs;
          }
        }
      }
      if (bestTracked == null) break;
      bestTracked.update(bestObserved!, smoothingAlpha);
      matched.add(bestTracked);
      unmatched.remove(bestObserved);
    }

    // Drop tracked hands that found no observation this tick.
    _hands.retainWhere(matched.contains);
    // Newly appeared hands.
    for (final obs in unmatched) {
      _hands.add(_SmoothedHand(obs));
    }

    for (final hand in _hands) {
      if (hand.isPinching) {
        if (hand.pinchRatio > pinchOff) hand.isPinching = false;
      } else {
        if (hand.pinchRatio < pinchOn) hand.isPinching = true;
      }
    }
  }
}
