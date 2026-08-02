import 'dart:ui' show Offset;

/// One tracked hand as reported by the native hand tracker (Patch 6).
class TrackedHand {
  TrackedHand({
    required this.pinchRatio,
    required this.cx,
    required this.cy,
    required this.confidence,
    this.landmarks = const [],
  });

  factory TrackedHand.fromMap(Map<dynamic, dynamic> map) => TrackedHand(
        pinchRatio: (map['pinchRatio'] as num).toDouble(),
        cx: (map['cx'] as num).toDouble(),
        cy: (map['cy'] as num).toDouble(),
        confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
        landmarks: (map['landmarks'] as List<dynamic>? ?? const [])
            .map((p) {
              final pair = p as List<dynamic>;
              return Offset(
                (pair[0] as num).toDouble(),
                (pair[1] as num).toDouble(),
              );
            })
            .toList(),
      );

  /// Thumb-index distance normalized by hand size (~0.2 pinched, ~1.0 open).
  final double pinchRatio;

  /// Pinch midpoint in view-normalized coordinates (0..1, origin top-left).
  final double cx;
  final double cy;

  /// Detection confidence 0..1.
  final double confidence;

  /// All 21 hand landmarks (MediaPipe index order) in view-normalized
  /// coordinates; joints the detector could not resolve are (-1, -1).
  /// May be empty on platforms/versions that do not send them.
  final List<Offset> landmarks;
}

/// A single hand-tracking tick streamed from the platform while hand tracking
/// is enabled. An empty [hands] list is still delivered on every tick.
class HandGestureFrame {
  HandGestureFrame({required this.timestampMs, required this.hands});

  factory HandGestureFrame.fromMap(Map<dynamic, dynamic> map) =>
      HandGestureFrame(
        timestampMs: (map['timestampMs'] as num).toInt(),
        hands: (map['hands'] as List<dynamic>? ?? const [])
            .map((h) => TrackedHand.fromMap(h as Map<dynamic, dynamic>))
            .toList(),
      );

  final int timestampMs;
  final List<TrackedHand> hands;
}
