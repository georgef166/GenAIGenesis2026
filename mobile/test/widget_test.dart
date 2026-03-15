import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:genai/src/ar_meshy_page.dart';
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

    expect(find.text('Meshy Prompt'), findsOneWidget);
    expect(find.text('Refining...'), findsOneWidget);

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
}

void _noop() {}
