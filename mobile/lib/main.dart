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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 16,
              left: 16,
              child: Text(
                'GENAI AR',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300, minWidth: 230),
                child: Container(
                  margin: const EdgeInsets.only(top: 12, right: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.22),
                    border: Border.all(
                      color: _primaryColor.withValues(alpha: 0.35),
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MenuButton(
                        title: 'AI Model Generator',
                        icon: Icons.auto_awesome_rounded,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ARMeshyPage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      _MenuButton(
                        title: 'Saturn V Rocket Explorer',
                        icon: Icons.rocket_launch_rounded,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ARRocketPage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      _MenuButton(
                        title: 'Saturn V Diagram',
                        icon: Icons.schema_rounded,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ARDiagramPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: _primaryColor.withValues(alpha: 0.92),
          foregroundColor: Colors.black,
          alignment: Alignment.centerLeft,
          shape: const BeveledRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(12),
              bottomRight: Radius.circular(12),
            ),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
