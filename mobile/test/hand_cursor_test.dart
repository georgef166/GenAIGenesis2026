import 'package:ar_flutter_plugin_2/models/hand_gesture_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genai/src/hand_cursor.dart';

/// One tracking tick. [at] is view-normalized (0..1); null means "no hand".
HandGestureFrame _frame(int ms, {Offset? at, double pinch = 1.0}) =>
    HandGestureFrame(
      timestampMs: ms,
      hands: at == null
          ? const []
          : [
              TrackedHand(
                pinchRatio: pinch,
                cx: at.dx,
                cy: at.dy,
                confidence: 1.0,
              ),
            ],
    );

/// Feeds [count] identical ticks 66 ms apart (the tracker's ~15 Hz), enough for
/// the cursor's EMA to settle on the pinch ratio.
Future<int> _hold(
  WidgetTester tester,
  HandCursorController controller,
  int startMs, {
  required Offset at,
  double pinch = 1.0,
  int count = 8,
}) async {
  var ms = startMs;
  for (var i = 0; i < count; i++) {
    controller.ingest(_frame(ms, at: at, pinch: pinch));
    await tester.pump();
    ms += 66;
  }
  return ms;
}

void main() {
  // The whole feature rests on this: a pinch has to press a real Material
  // control through the same code path a finger uses.
  testWidgets('a pinch over a snapped button presses it', (tester) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Center(
                child: FilledButton(
                  onPressed: () => taps++,
                  child: const Text('Generate'),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final centre = tester.getCenter(find.byType(FilledButton));
    final size = tester.getSize(find.byKey(rootKey));
    final at = Offset(centre.dx / size.width, centre.dy / size.height);

    final ms = await _hold(tester, controller, 0, at: at);
    expect(controller.isSnapped, isTrue, reason: 'cursor should snap first');
    expect(taps, 0);

    await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1);

    // Rising edge only: holding the pinch must not autorepeat.
    await _hold(tester, controller, ms + 1000, at: at, pinch: 0.15);
    expect(taps, 1);
  });

  testWidgets('snap picks the nearest control and ignores anything outside '
      'the radius', (tester) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Positioned(
                left: 40,
                top: 40,
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('Fast'),
                ),
              ),
              Positioned(
                left: 40,
                top: 200,
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('Quality'),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byKey(rootKey));
    Rect? snapFor(Offset global) {
      controller.clear();
      controller.ingest(
        _frame(
          0,
          at: Offset(global.dx / size.width, global.dy / size.height),
        ),
      );
      return controller.value.snapRect;
    }

    final fast = tester.getRect(find.widgetWithText(FilledButton, 'Fast'));
    final quality = tester.getRect(
      find.widgetWithText(FilledButton, 'Quality'),
    );

    // 20 px above "Fast" — inside the radius, and much closer than "Quality".
    final near = snapFor(fast.center.translate(0, -fast.height / 2 - 20));
    expect(near, isNotNull);
    expect(near!.center.dy, lessThan(quality.top));

    // Halfway between them: both are >60 px away, so nothing snaps.
    expect(snapFor(Offset(fast.center.dx, (fast.bottom + quality.top) / 2)),
        isNull);
  });

  // Same regression as the gesture chip: an overlay that hit-tests while
  // invisible swallows the drags meant for the AR view underneath it.
  testWidgets('the overlay does not steal input', (tester) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var tapsReachingTheArView = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => tapsReachingTheArView++,
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    controller.ingest(_frame(0, at: const Offset(0.5, 0.5), pinch: 0.15));
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(tapsReachingTheArView, 1);
  });

  // A synthetic pointer left down would keep the recognizer tracking it and
  // reject the next real finger, permanently wedging the control.
  testWidgets('a pinch that vanishes leaves no pointer stuck down', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Center(
                child: FilledButton(
                  onPressed: () => taps++,
                  child: const Text('Generate'),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final centre = tester.getCenter(find.byType(FilledButton));
    final size = tester.getSize(find.byKey(rootKey));
    final at = Offset(centre.dx / size.width, centre.dy / size.height);

    final ms = await _hold(tester, controller, 0, at: at);
    await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1);

    // Hand disappears mid-pinch.
    controller.ingest(_frame(ms + 1000));
    await tester.pump();
    expect(controller.value.cursor, isNull);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(taps, 2, reason: 'a real finger must still reach the button');
  });

  // The hold exists because detection blinks. If it holds the position but not
  // the pinch, the blink itself reads as a release-and-re-press: Generate
  // submitted twice, or a mode chip toggled straight back off.
  testWidgets('a dropped frame mid-pinch does not fire a second click', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Center(
                child: FilledButton(
                  onPressed: () => taps++,
                  child: const Text('Generate'),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final centre = tester.getCenter(find.byType(FilledButton));
    final size = tester.getSize(find.byKey(rootKey));
    final at = Offset(centre.dx / size.width, centre.dy / size.height);

    var ms = await _hold(tester, controller, 0, at: at);
    ms = await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1);

    // One missed detection tick, well inside the 300 ms hold, then the same
    // pinch resumes.
    controller.ingest(_frame(ms));
    await tester.pump();
    ms += 66;
    await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1, reason: 'the blink is not a new press');
  });

  // clear() runs on the app-bar toggle and on pause. The controller's own
  // interpreter keeps its latched pinch, so without resetting it, coming back
  // with fingers still closed reads as a fresh rising edge.
  testWidgets('clear() then a still-pinched hand does not click', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Center(
                child: FilledButton(
                  onPressed: () => taps++,
                  child: const Text('Generate'),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final centre = tester.getCenter(find.byType(FilledButton));
    final size = tester.getSize(find.byKey(rootKey));
    final at = Offset(centre.dx / size.width, centre.dy / size.height);

    var ms = await _hold(tester, controller, 0, at: at);
    ms = await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1);

    controller.clear();
    await tester.pump();
    await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(taps, 1, reason: 'resuming an already-closed hand is not a press');
  });

  // The recents rail: a scrollable is a pointer listener too, and it is small
  // enough to pass the area cap. Its own centre falls in the gap between two
  // cards (200 px cards, 10 px separators), so probing there confirms the row
  // itself — and the click then lands in that gap, leaving the card the cursor
  // is actually over permanently unreachable. Hence the 410 px viewport: its
  // centre is exactly the first separator.
  testWidgets('a scrollable row does not swallow the cards inside it', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final controller = HandCursorController(rootKey: rootKey);
    addTearDown(controller.dispose);
    var tappedCard = -1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: rootKey,
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: 92,
                  width: 410,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: 4,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) => GestureDetector(
                      onTap: () => tappedCard = index,
                      child: Container(width: 200, color: Colors.blueGrey),
                    ),
                  ),
                ),
              ),
              HandCursorOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    final row = tester.getRect(find.byType(ListView));
    final card = tester.getRect(find.byType(GestureDetector).first);
    expect(
      card.contains(row.center),
      isFalse,
      reason: 'the row centre must fall in a gap for this to test anything',
    );

    final size = tester.getSize(find.byKey(rootKey));
    final at = Offset(
      card.center.dx / size.width,
      card.center.dy / size.height,
    );

    final ms = await _hold(tester, controller, 0, at: at);
    expect(controller.value.snapRect?.width, 200, reason: 'the card, not row');

    await _hold(tester, controller, ms, at: at, pinch: 0.15);
    expect(tappedCard, 0);
  });

  group('landscape', () {
    testWidgets('the cursor still snaps and clicks on a landscape phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2340, 1080);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      final rootKey = GlobalKey();
      final controller = HandCursorController(rootKey: rootKey);
      addTearDown(controller.dispose);
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              key: rootKey,
              children: [
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FilledButton(
                    onPressed: () => taps++,
                    child: const Text('Generate model'),
                  ),
                ),
                HandCursorOverlay(controller: controller),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      final centre = tester.getCenter(find.byType(FilledButton));
      final size = tester.getSize(find.byKey(rootKey));
      final at = Offset(centre.dx / size.width, centre.dy / size.height);

      final ms = await _hold(tester, controller, 0, at: at);
      await _hold(tester, controller, ms, at: at, pinch: 0.15);
      expect(taps, 1);
    });
  });
}
