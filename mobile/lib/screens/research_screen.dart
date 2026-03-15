import 'package:flutter/material.dart';

import '../models/research_result.dart';
import '../services/langflow_service.dart';

class ResearchScreen extends StatefulWidget {
  const ResearchScreen({super.key});

  @override
  State<ResearchScreen> createState() => _ResearchScreenState();
}

class _ResearchScreenState extends State<ResearchScreen> {
  static const _baseUrl = String.fromEnvironment(
    'LANGFLOW_BASE_URL',
    defaultValue: 'https://aws-us-east-2.langflow.datastax.com',
  );
  static const _flowId = String.fromEnvironment(
    'LANGFLOW_FLOW_ID',
    defaultValue: '52f27664-602e-4012-bafd-0bf43bb1701c',
  );
  static const _appToken = String.fromEnvironment('LANGFLOW_APP_TOKEN');

  final _topicController = TextEditingController();
  late final LangFlowService _service;

  bool _isLoading = false;
  ResearchResult? _researchResult;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = LangFlowService(
      baseUrl: _baseUrl,
      flowId: _flowId,
      appToken: _appToken,
    );
  }

  @override
  void dispose() {
    _topicController.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _submitTopic() async {
    if (_appToken.isEmpty) {
      setState(() {
        _error =
            'Missing LANGFLOW_APP_TOKEN. Start the app with --dart-define.';
      });
      return;
    }

    final topic = _topicController.text.trim();
    if (topic.isEmpty) {
      setState(() {
        _error = 'Please enter a topic first.';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _error = null;
      _researchResult = null;
    });

    try {
      final result = await _service.fetchResearch(topic);
      if (!mounted) {
        return;
      }
      setState(() {
        _researchResult = result;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not load facts. $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Topic Research Lab'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF051937),
              Color(0xFF004D7A),
              Color(0xFF008793),
              Color(0xFF00BF72),
            ],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: Colors.white.withValues(alpha: 0.92),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Type a topic and discover fun facts!',
                        style: TextStyle(
                          color: Color(0xFF1B1F24),
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _topicController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _submitTopic(),
                        decoration: InputDecoration(
                          hintText: 'Examples: dolphins, volcano, rainbows',
                          filled: true,
                          fillColor: const Color(0xFFF8FAFF),
                          prefixIcon: const Icon(Icons.lightbulb_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _submitTopic,
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('Generate Fun Facts'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF8A00),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (_error != null)
                Card(
                  color: Colors.red.shade100,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              if (_researchResult != null) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _researchResult!.topic,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                ...List.generate(_researchResult!.facts.length, (index) {
                  final colors = <Color>[
                    const Color(0xFFFFF176),
                    const Color(0xFFFFAB91),
                    const Color(0xFFA5D6A7),
                    const Color(0xFF80DEEA),
                    const Color(0xFFCE93D8),
                    const Color(0xFF9FA8DA),
                  ];

                  return _FactFlashcard(
                    factNumber: index + 1,
                    text: _researchResult!.facts[index],
                    color: colors[index % colors.length],
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FactFlashcard extends StatelessWidget {
  const _FactFlashcard({
    required this.factNumber,
    required this.text,
    required this.color,
  });

  final int factNumber;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: Colors.white,
              child: Text(
                '$factNumber',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF1A1A1A),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
