import 'package:flutter/material.dart';

import 'src/ar_meshy_page.dart';
import 'src/ar_rocket_page.dart';
import 'src/ar_diagram_page.dart';

// ---------------------------------------------------------------------------
// Main entry point & App root
// ---------------------------------------------------------------------------

const _backgroundColor = Color(0xFF02040a);
const _primaryColor = Color(0xFF00ffff);
const _lightColor = Color(0xFF80ffde);

void main() {
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
          background: _backgroundColor,
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
      appBar: AppBar(title: const Text('GENAI AR EXPERIENCES')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.view_in_ar_rounded,
                size: 80,
                color: _primaryColor,
              ),
              const SizedBox(height: 32),
              Text(
                'Choose a Holo-interface',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1,
                    ),
              ),
              const SizedBox(height: 48),
              _FeatureCard(
                title: 'AI Model Generator',
                subtitle: 'Generate 3D objects with Meshy and place them in AR',
                icon: Icons.auto_awesome_rounded,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ARMeshyPage()),
                  );
                },
              ),
              const SizedBox(height: 16),
              _FeatureCard(
                title: 'Saturn V Rocket Explorer',
                subtitle: "Examine NASA's Saturn V rocket in detailed AR",
                icon: Icons.rocket_launch_rounded,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ARRocketPage()),
                  );
                },
              ),
              const SizedBox(height: 16),
              _FeatureCard(
                title: 'Saturn V Diagram',
                subtitle:
                    'Museum-style AR educational labels for each rocket section',
                icon: Icons.schema_rounded,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ARDiagramPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.black.withOpacity(0.25),
      elevation: 0,
      shape: BeveledRectangleBorder(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        side: BorderSide(color: _primaryColor.withOpacity(0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: _primaryColor.withOpacity(0.2),
        highlightColor: _primaryColor.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _lightColor.withOpacity(0.5)),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryColor.withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(icon, size: 28, color: _lightColor),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.1,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: _lightColor.withOpacity(0.8),
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded, color: _primaryColor),
            ],
          ),
        ),
      ),
    );
  }
}
