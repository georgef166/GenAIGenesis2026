import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:genai/main.dart';

void main() {
  testWidgets('overlay shows reset action when a dot is placed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ARStatusOverlay(
            state: ARPlacementState.placed,
            message: 'Dot placed. Use reset to place it somewhere else.',
            isHorizontalPlaneAvailable: true,
            primaryActionLabel: null,
            onPrimaryAction: null,
            showReset: true,
            onReset: _noop,
            planeCount: 1,
          ),
        ),
      ),
    );

    expect(find.text('Dot anchored'), findsOneWidget);
    expect(find.text('Reset dot'), findsOneWidget);
    expect(find.text('Horizontal plane detected'), findsOneWidget);
    expect(find.text('1 plane tracked'), findsOneWidget);
  });
}

void _noop() {}
