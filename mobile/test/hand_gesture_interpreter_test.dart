import 'package:ar_flutter_plugin_2/models/hand_gesture_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genai/src/gesture_transform_math.dart';
import 'package:genai/src/hand_gesture_interpreter.dart';
import 'package:vector_math/vector_math_64.dart';

HandGestureFrame frame(int ts, List<TrackedHand> hands) =>
    HandGestureFrame(timestampMs: ts, hands: hands);

TrackedHand hand(double x, double y,
        {double pinch = 1.0, double confidence = 1.0}) =>
    TrackedHand(pinchRatio: pinch, cx: x, cy: y, confidence: confidence);

/// Interpreter with no smoothing so tests can reason about exact values.
HandGestureInterpreter makeInterpreter() => HandGestureInterpreter(
      smoothingAlpha: 1.0,
      viewAspect: 1.0,
    );

void main() {
  group('pinch hysteresis', () {
    test('pinch starts below pinchOn and holds until above pinchOff', () {
      final interp = makeInterpreter();

      // Ratio between thresholds: not pinching yet.
      var cmds = interp.ingest(frame(0, [hand(0.5, 0.5, pinch: 0.45)]));
      expect(cmds, isEmpty);

      // Below pinchOn: drag starts.
      cmds = interp.ingest(frame(33, [hand(0.5, 0.5, pinch: 0.30)]));
      expect(cmds.single, isA<DragStart>());

      // Back into the hysteresis band: still dragging.
      cmds = interp.ingest(frame(66, [hand(0.55, 0.5, pinch: 0.45)]));
      expect(cmds.single, isA<DragUpdate>());

      // Above pinchOff: released.
      cmds = interp.ingest(frame(99, [hand(0.55, 0.5, pinch: 0.60)]));
      expect(cmds.single, isA<DragEnd>());
    });
  });

  group('drag', () {
    test('cumulative drag deltas equal the synthetic path', () {
      final interp = makeInterpreter();
      interp.ingest(frame(0, [hand(0.2, 0.2, pinch: 0.2)]));

      var total = Offset.zero;
      final path = [
        const Offset(0.25, 0.2),
        const Offset(0.3, 0.25),
        const Offset(0.4, 0.4),
      ];
      var ts = 33;
      for (final p in path) {
        final cmds = interp.ingest(frame(ts, [hand(p.dx, p.dy, pinch: 0.2)]));
        for (final c in cmds) {
          if (c is DragUpdate) total += c.delta;
        }
        ts += 33;
      }
      expect(total.dx, closeTo(0.4 - 0.2, 1e-9));
      expect(total.dy, closeTo(0.4 - 0.2, 1e-9));
    });

    test('survives a short dropout but ends after the grace period', () {
      final interp = makeInterpreter();
      interp.ingest(frame(0, [hand(0.5, 0.5, pinch: 0.2)]));

      // Two dropped ticks within 180 ms: gesture held, no commands.
      expect(interp.ingest(frame(66, [])), isEmpty);
      expect(interp.ingest(frame(132, [])), isEmpty);

      // Hand returns: drag continues without a restart.
      final resumed = interp.ingest(frame(165, [hand(0.55, 0.5, pinch: 0.2)]));
      expect(resumed.whereType<DragStart>(), isEmpty);
      expect(resumed.whereType<DragUpdate>(), isNotEmpty);

      // Long dropout: drag ends.
      expect(interp.ingest(frame(200, [])), isEmpty); // within grace
      final ended = interp.ingest(frame(500, []));
      expect(ended.single, isA<DragEnd>());
    });

    test('low-confidence hands are ignored', () {
      final interp = makeInterpreter();
      final cmds = interp
          .ingest(frame(0, [hand(0.5, 0.5, pinch: 0.2, confidence: 0.3)]));
      expect(cmds, isEmpty);
    });
  });

  group('zoom', () {
    test('two-hand spread emits increasing span ratios', () {
      final interp = makeInterpreter();
      var cmds = interp.ingest(frame(0, [
        hand(0.4, 0.5, pinch: 0.2),
        hand(0.6, 0.5, pinch: 0.2),
      ]));
      expect(cmds.whereType<ZoomStart>(), isNotEmpty);

      final ratios = <double>[];
      var ts = 33;
      for (final spread in [0.25, 0.3, 0.35]) {
        cmds = interp.ingest(frame(ts, [
          hand(0.5 - spread, 0.5, pinch: 0.2),
          hand(0.5 + spread, 0.5, pinch: 0.2),
        ]));
        ratios.addAll(cmds.whereType<ZoomUpdate>().map((z) => z.spanRatio));
        ts += 33;
      }
      expect(ratios.length, 3);
      expect(ratios[0], closeTo(2.5, 1e-6));
      expect(ratios[1], closeTo(3.0, 1e-6));
      expect(ratios[2], closeTo(3.5, 1e-6));
    });

    test('releasing one hand transitions zoom -> drag with a fresh baseline',
        () {
      final interp = makeInterpreter();
      interp.ingest(frame(0, [
        hand(0.4, 0.5, pinch: 0.2),
        hand(0.6, 0.5, pinch: 0.2),
      ]));
      // One hand releases its pinch while both stay visible.
      final cmds = interp.ingest(frame(33, [
        hand(0.4, 0.5, pinch: 0.2),
        hand(0.6, 0.5, pinch: 0.7),
      ]));
      expect(cmds[0], isA<ZoomEnd>());
      expect(cmds[1], isA<DragStart>());

      // Next movement produces a delta relative to the re-anchored point.
      final next = interp.ingest(frame(66, [
        hand(0.45, 0.5, pinch: 0.2),
        hand(0.6, 0.5, pinch: 0.7),
      ]));
      final update = next.whereType<DragUpdate>().single;
      expect(update.delta.dx, closeTo(0.05, 1e-9));
    });

    test('hand identity is stable when hands cross', () {
      final interp = makeInterpreter();
      interp.ingest(frame(0, [
        hand(0.3, 0.5, pinch: 0.2),
        hand(0.7, 0.5, pinch: 0.2),
      ]));
      // Hands move toward each other and pass; span shrinks then grows.
      final r1 = interp
          .ingest(frame(33, [
            hand(0.45, 0.5, pinch: 0.2),
            hand(0.55, 0.5, pinch: 0.2),
          ]))
          .whereType<ZoomUpdate>()
          .single;
      expect(r1.spanRatio, closeTo(0.25, 1e-6));

      final r2 = interp
          .ingest(frame(66, [
            hand(0.55, 0.5, pinch: 0.2),
            hand(0.45, 0.5, pinch: 0.2),
          ]))
          .whereType<ZoomUpdate>()
          .single;
      // Same physical spread; still zooming, no spurious restart.
      expect(r2.spanRatio, closeTo(0.25, 1e-6));
    });
  });

  group('computeAnchorLocalDelta', () {
    test('identity poses map screen delta to camera right/up', () {
      final delta = computeAnchorLocalDelta(
        cameraPose: Matrix4.identity(),
        anchorPose: Matrix4.identity(),
        normDelta: const Offset(0.1, -0.05),
        distance: 2.0,
        viewAspect: 1.0,
        kFov: 1.4,
      );
      // right = +x, up = +y; screen down is negative dy -> +up.
      expect(delta.x, closeTo(0.1 * 2.0 * 1.4, 1e-9));
      expect(delta.y, closeTo(0.05 * 2.0 * 1.4, 1e-9));
      expect(delta.z, closeTo(0.0, 1e-9));
    });

    test('vertical delta is divided by the view aspect', () {
      // kFov calibrates the horizontal FOV, and dy is a fraction of *height*,
      // so on the app's landscape aspect a full-height drag must move the
      // object by the frustum's height, not its width. Without the division
      // vertical drag overshoots the finger by the aspect ratio.
      const aspect = 2340 / 1080;
      final delta = computeAnchorLocalDelta(
        cameraPose: Matrix4.identity(),
        anchorPose: Matrix4.identity(),
        normDelta: const Offset(0.25, -0.25),
        distance: 2.0,
        viewAspect: aspect,
        kFov: 1.4,
      );
      expect(delta.x, closeTo(0.25 * 2.0 * 1.4, 1e-9));
      expect(delta.y, closeTo(0.25 * 2.0 * 1.4 / aspect, 1e-9));
      // Equal-magnitude screen components must not come back equal in world
      // space on a non-square view — that is what makes diagonals curve.
      expect(delta.y, lessThan(delta.x));
    });

    test('anchor rotation converts world delta into anchor space', () {
      // Anchor rotated 90 degrees around Y: world +x becomes anchor -z.
      final anchorPose = Matrix4.rotationY(3.141592653589793 / 2);
      final delta = computeAnchorLocalDelta(
        cameraPose: Matrix4.identity(),
        anchorPose: anchorPose,
        normDelta: const Offset(0.1, 0),
        distance: 1.0,
        viewAspect: 1.0,
        kFov: 1.0,
      );
      expect(delta.x.abs(), lessThan(1e-9));
      expect(delta.z, closeTo(0.1, 1e-9));
    });
  });
}
