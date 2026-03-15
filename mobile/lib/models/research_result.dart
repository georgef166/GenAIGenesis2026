class ResearchResult {
  const ResearchResult({
    required this.topic,
    required this.fact1,
    required this.fact2,
    required this.fact3,
    required this.fact4,
    required this.fact5,
    required this.fact6,
  });

  final String topic;
  final String fact1;
  final String fact2;
  final String fact3;
  final String fact4;
  final String fact5;
  final String fact6;

  List<String> get facts => [fact1, fact2, fact3, fact4, fact5, fact6];

  factory ResearchResult.fromJson(Map<String, dynamic> json) {
    String readField(String key) => (json[key] ?? '').toString().trim();

    return ResearchResult(
      topic: readField('topic'),
      fact1: readField('fact1'),
      fact2: readField('fact2'),
      fact3: readField('fact3'),
      fact4: readField('fact4'),
      fact5: readField('fact5'),
      fact6: readField('fact6'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'topic': topic,
      'fact1': fact1,
      'fact2': fact2,
      'fact3': fact3,
      'fact4': fact4,
      'fact5': fact5,
      'fact6': fact6,
    };
  }
}
