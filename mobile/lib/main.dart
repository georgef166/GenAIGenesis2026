import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/ar_meshy_page.dart';
import 'src/ar_rocket_page.dart';
import 'src/ar_diagram_page.dart';

// ---------------------------------------------------------------------------
// Main entry point & App root
// ---------------------------------------------------------------------------

const _backgroundColor = Color(0xFF02040a);
const _primaryColor = Color(0xFF00ffff);
const _lightColor = Color(0xFF80ffde);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const GenaiApp());
}

class GenaiApp extends StatelessWidget {
  const GenaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GenAI AR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _primaryColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: _backgroundColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        textTheme: Theme.of(context).textTheme.apply(
          fontFamily: 'RobotoMono',
          bodyColor: _lightColor,
          displayColor: Colors.white,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Home page: Feature selection
// ---------------------------------------------------------------------------

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openScreen(BuildContext context, Widget child) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => _TopRightBackShell(child: child)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              right: 0,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 235, minWidth: 210),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    border: Border.all(
                      color: _primaryColor.withValues(alpha: 0.3),
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MenuButton(
                        title: 'AI Model Generator',
                        icon: Icons.auto_awesome_rounded,
                        onTap: () {
                          _openScreen(context, const ARMeshyPage());
                        },
                      ),
                      const SizedBox(height: 6),
                      _MenuButton(
                        title: 'Saturn V Rocket Explorer',
                        icon: Icons.rocket_launch_rounded,
                        onTap: () {
                          _openScreen(context, const ARRocketPage());
                        },
                      ),
                      const SizedBox(height: 6),
                      _MenuButton(
                        title: 'Saturn V Diagram',
                        icon: Icons.schema_rounded,
                        onTap: () {
                          _openScreen(context, const ARDiagramPage());
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Align(
              child: Text(
                'GENAI AR EXPERIENCES',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: _primaryColor.withValues(alpha: 0.96),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopRightBackShell extends StatelessWidget {
  const _TopRightBackShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: _MenuButton(
              title: 'Back',
              icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.of(context).maybePop(),
              width: 108,
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.title,
    required this.icon,
    required this.onTap,
    this.width,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      width: width ?? double.infinity,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          backgroundColor: _primaryColor.withValues(alpha: 0.92),
          foregroundColor: Colors.black,
          alignment: Alignment.centerLeft,
          shape: const BeveledRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
          ),
        ),
        icon: Icon(icon, size: 14),
        label: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
