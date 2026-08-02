import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Re-exports ImageSource and XFile, and lets the tests below swap the picker.
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:genai/src/ar_meshy_page.dart';
// Its ARStatusOverlay is a different class that happens to share the name.
import 'package:genai/src/ar_rocket_page.dart' as rocket;
import 'package:genai/src/meshy_model_history.dart';

void main() {
  testWidgets('overlay shows reset action when a model is placed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ARStatusOverlay(
            title: 'Model anchored',
            message:
                'Model placed. Reset to place it again or generate a new prompt.',
            icon: Icons.touch_app_rounded,
            planeChipLabel: 'Horizontal plane detected',
            generationChipLabel: 'Model ready',
            placementChipLabel: 'Model anchored',
            planeCount: 1,
            primaryActionLabel: null,
            onPrimaryAction: null,
            showReset: true,
            onReset: _noop,
          ),
        ),
      ),
    );

    expect(find.text('Model anchored'), findsNWidgets(2));
    expect(find.text('Reset placement'), findsOneWidget);
    expect(find.text('Horizontal plane detected'), findsOneWidget);
    expect(find.text('1 plane tracked'), findsOneWidget);
  });

  testWidgets('overlay can show live Meshy progress', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ARStatusOverlay(
            title: 'Generating preview',
            message: 'Preview is 42% complete. Meshy status: IN_PROGRESS.',
            icon: Icons.auto_awesome_rounded,
            planeChipLabel: 'Scanning for horizontal plane',
            generationChipLabel: 'Preview 42%',
            placementChipLabel: 'Single model mode',
            planeCount: 0,
            primaryActionLabel: null,
            onPrimaryAction: null,
            showReset: false,
            onReset: _noop,
          ),
        ),
      ),
    );

    expect(find.text('Generating preview'), findsOneWidget);
    expect(find.text('Preview 42%'), findsOneWidget);
    expect(find.text('Scanning for horizontal plane'), findsOneWidget);
  });

  testWidgets('prompt panel disables generation while a job is running', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController(text: 'a carved obsidian fox');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeshyPromptPanel(
            promptController: controller,
            helperText: 'Meshy is refining the model now.',
            generateLabel: 'Refining...',
            onGenerate: null,
          ),
        ),
      ),
    );

    expect(find.text('Generation'), findsOneWidget);
    expect(find.text('Refining...'), findsOneWidget);
    expect(find.text('Fast · 12 steps'), findsNothing);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('prompt panel can surface and load recent models', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController();
    MeshyModelRecord? selectedRecord;
    addTearDown(controller.dispose);

    final record = MeshyModelRecord(
      id: 'job-1',
      prompt: 'a brass owl automaton',
      localRelativePath: 'meshy_models/job-1.glb',
      originalGlbUrl: 'https://example.com/job-1.glb',
      createdAt: DateTime.utc(2026, 3, 15, 12),
      updatedAt: DateTime.utc(2026, 3, 15, 12),
      lastUsedAt: DateTime.utc(2026, 3, 15, 12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeshyPromptPanel(
            promptController: controller,
            helperText: 'Load a recent model or generate a new one.',
            generateLabel: 'Generate model',
            onGenerate: _noop,
            recentModels: <MeshyModelRecord>[record],
            onSelectRecentModel: (selected) {
              selectedRecord = selected;
            },
          ),
        ),
      ),
    );

    expect(find.text('Recent Models'), findsOneWidget);
    expect(find.text('a brass owl automaton'), findsOneWidget);

    await tester.tap(find.text('a brass owl automaton'));
    await tester.pump();

    expect(selectedRecord?.id, 'job-1');
  });

  testWidgets('prompt panel offers a photo source in world mode', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController(text: 'a sunlit alpine meadow');
    ImageSource? requestedSource;
    int? requestedSteps;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeshyPromptPanel(
            promptController: controller,
            helperText: 'Add a photo to expand into a world.',
            generateLabel: 'Generate world',
            // The page disables this until a photo is chosen.
            onGenerate: null,
            kind: 'world',
            onPickImage: (source) => requestedSource = source,
            onWorldStepsChanged: (steps) => requestedSteps = steps,
          ),
        ),
      ),
    );

    expect(
      find.text('Add a photo to expand into a 360 world.'),
      findsOneWidget,
    );
    expect(find.text('Fast · 12 steps'), findsOneWidget);
    expect(find.text('Quality · 40 steps'), findsOneWidget);

    await tester.tap(find.text('Quality · 40 steps'));
    await tester.pump();
    expect(requestedSteps, 40);

    await tester.tap(find.text('Gallery'));
    await tester.pump();

    expect(requestedSource, ImageSource.gallery);
  });

  testWidgets('collapse pill mirrors the generation state', (
    WidgetTester tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeshyPromptPill(isGenerating: false, onTap: () => taps++),
        ),
      ),
    );

    expect(find.text('Prompt'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byType(MeshyPromptPill));
    await tester.pump();
    expect(taps, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeshyPromptPill(isGenerating: true, onTap: () => taps++),
        ),
      ),
    );

    expect(find.text('Generating...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('accepting a generation collapses the panel behind a pill', (
    WidgetTester tester,
  ) async {
    final responses = _FakeProxy(
      createResponse: (202, '{"jobId":"job-1","status":"submitting",'
          '"prompt":"a brass owl"}'),
      pollResponse: (200, '{"jobId":"job-1","status":"previewing",'
          '"prompt":"a brass owl","progress":42}'),
    );
    _installFakes(tester, responses);

    await tester.pumpWidget(const MaterialApp(home: ARMeshyPage()));
    await _tick(tester);

    await tester.tap(find.text('Gallery'));
    await _tick(tester);
    await tester.enterText(find.byType(TextField), 'a brass owl');
    await _tick(tester);

    await tester.tap(find.text('Generate model'));
    await _tick(tester);

    expect(find.byType(MeshyPromptPanel), findsNothing);
    expect(find.byType(MeshyPromptPill), findsOneWidget);
    expect(find.text('Generating...'), findsOneWidget);

    // The pill is the always-visible way back — the whole point of it living
    // outside the panel it hides.
    await tester.tap(find.byType(MeshyPromptPill));
    await _tick(tester);

    expect(find.byType(MeshyPromptPanel), findsOneWidget);
    expect(find.byType(MeshyPromptPill), findsNothing);

    // Let the poll loop end so no timer outlives the test.
    responses.pollResponse = (200, '{"jobId":"job-1","status":"error",'
        '"prompt":"a brass owl","error":"backend gave up"}');
    await tester.pump(const Duration(seconds: 3));
    await _tick(tester);
  });

  // The app is landscape-locked, so ~411 logical px of height is all the
  // overlays ever get. The bottom prompt-panel reserve used to be a hardcoded
  // 220, which left the 264 px status overlay 175 px to live in — the "bottom
  // overflowed by 89 pixels" banner users saw on device.
  group('landscape', () {
    void useLandscapePhone(WidgetTester tester) {
      tester.view.physicalSize = const Size(2340, 1080);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
    }

    testWidgets('the meshy page lays out without overflowing', (
      WidgetTester tester,
    ) async {
      useLandscapePhone(tester);
      _installFakes(
        tester,
        _FakeProxy(
          createResponse: (202, '{"jobId":"job-3","status":"submitting"}'),
          pollResponse: (200, '{"jobId":"job-3","status":"submitting"}'),
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: ARMeshyPage()));
      await _tick(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('the status overlay scrolls rather than overflowing', (
      WidgetTester tester,
    ) async {
      useLandscapePhone(tester);

      // 175 px is exactly what the old hardcoded 220 bottom reserve left on
      // this device, against ~264 px of worst case content (an action button
      // *and* a reset button). It must scroll, not overflow.
      const budget = 175.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: budget,
                child: ARStatusOverlay(
                  title: 'Model anchored',
                  message:
                      'Model placed. Reset to place it again or generate a '
                      'new prompt.',
                  icon: Icons.touch_app_rounded,
                  planeChipLabel: 'Horizontal plane detected',
                  generationChipLabel: 'Model ready',
                  placementChipLabel: 'Model anchored',
                  planeCount: 1,
                  primaryActionLabel: 'Enable camera',
                  onPrimaryAction: _noop,
                  showReset: true,
                  onReset: _noop,
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // Squeezed into the height it was offered instead of overrunning it.
      expect(tester.getSize(find.byType(ARStatusOverlay)).height, budget);
      // Still reachable — by scrolling.
      await tester.drag(find.byType(ARStatusOverlay), const Offset(0, -200));
      await tester.pump();
      expect(find.text('Reset placement'), findsOneWidget);
    });

    // Same latent bug, same fix: this overlay wants 328 px in its fullest
    // state and the rocket page's Column only ever had ~319 px left for it
    // once the "explore parts" button took its share.
    testWidgets('the rocket overlay scrolls rather than overflowing', (
      WidgetTester tester,
    ) async {
      useLandscapePhone(tester);

      const budget = 175.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: budget,
                child: rocket.ARStatusOverlay(
                  state: rocket.ARPlacementState.placed,
                  message: 'Rocket placed. Reset it to place it again.',
                  isHorizontalPlaneAvailable: true,
                  primaryActionLabel: null,
                  onPrimaryAction: null,
                  showReset: true,
                  onReset: _noop,
                  planeCount: 3,
                  launchPhase: rocket.LaunchPhase.lifting,
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(rocket.ARStatusOverlay)).height,
        budget,
      );
    });

    testWidgets('the prompt panel lays out without overflowing', (
      WidgetTester tester,
    ) async {
      useLandscapePhone(tester);
      final controller = TextEditingController(text: 'a sunlit alpine meadow');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              // Mirrors how the page mounts the panel.
              child: SingleChildScrollView(
                child: MeshyPromptPanel(
                  promptController: controller,
                  helperText: 'Add a photo to expand into a world.',
                  generateLabel: 'Generate world',
                  onGenerate: _noop,
                  kind: 'world',
                  onPickImage: (_) {},
                  recentModels: <MeshyModelRecord>[
                    MeshyModelRecord(
                      id: 'job-1',
                      prompt: 'a brass owl automaton',
                      localRelativePath: 'meshy_models/job-1.glb',
                      originalGlbUrl: 'https://example.com/job-1.glb',
                      createdAt: DateTime.utc(2026, 3, 15, 12),
                      updatedAt: DateTime.utc(2026, 3, 15, 12),
                      lastUsedAt: DateTime.utc(2026, 3, 15, 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a generation error reopens the prompt panel', (
    WidgetTester tester,
  ) async {
    _installFakes(
      tester,
      _FakeProxy(
        createResponse: (202, '{"jobId":"job-2","status":"submitting",'
            '"prompt":"a brass owl"}'),
        pollResponse: (200, '{"jobId":"job-2","status":"error",'
            '"prompt":"a brass owl","error":"backend gave up"}'),
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: ARMeshyPage()));
    await _tick(tester);

    await tester.tap(find.text('Gallery'));
    await _tick(tester);
    await tester.enterText(find.byType(TextField), 'a brass owl');
    await _tick(tester);

    await tester.tap(find.text('Generate model'));
    await _tick(tester);

    expect(find.byType(MeshyPromptPanel), findsOneWidget);
    expect(find.byType(MeshyPromptPill), findsNothing);
    expect(find.text('backend gave up'), findsWidgets);
  });
}

void _noop() {}

/// The page's "Recent Models" spinner never resolves off-device (path_provider
/// has no test implementation), so `pumpAndSettle` would hang. Pump a fixed
/// window instead — long enough for the 200 ms collapse animation.
Future<void> _tick(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Swaps the photo picker and the proxy transport for in-memory fakes so the
/// page's generation flow can be driven without a device or a server.
void _installFakes(WidgetTester tester, _FakeProxy proxy) {
  final previousPicker = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = _FakeImagePicker();
  addTearDown(() => ImagePickerPlatform.instance = previousPicker);

  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = _FakeHttpOverrides(proxy);
  addTearDown(() => HttpOverrides.global = previousOverrides);
}

class _FakeProxy {
  _FakeProxy({required this.createResponse, required this.pollResponse});

  (int, String) createResponse;
  (int, String) pollResponse;

  (int, String) respond(String method) =>
      method == 'POST' ? createResponse : pollResponse;
}

class _FakeImagePicker extends ImagePickerPlatform {
  /// A 1x1 PNG: the panel renders the picked bytes, so they have to decode.
  static final _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile.fromData(_pixel);
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.proxy);

  final _FakeProxy proxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(proxy);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.proxy);

  final _FakeProxy proxy;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest(proxy.respond(method));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.response);

  final (int, String) response;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  void write(Object? object) {}

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpClientResponse(response.$1, response.$2);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.body);

  @override
  final int statusCode;

  final String body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
