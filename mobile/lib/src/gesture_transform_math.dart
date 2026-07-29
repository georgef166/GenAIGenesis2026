import 'dart:ui' show Offset;

import 'package:vector_math/vector_math_64.dart';

/// Maps a view-normalized drag delta to an anchor-local translation.
///
/// The object moves in the camera-facing plane at its current distance:
/// screen-right maps to the camera's right vector and screen-down to the
/// camera's negative up vector, scaled by distance and [kFov]
/// (approximately 2*tan(horizontalFov/2); tuned constant since the plugin
/// exposes no camera intrinsics).
Vector3 computeAnchorLocalDelta({
  required Matrix4 cameraPose,
  required Matrix4 anchorPose,
  required Offset normDelta,
  required double distance,
  double kFov = 1.4,
}) {
  final cameraRight =
      Vector3(cameraPose.entry(0, 0), cameraPose.entry(1, 0), cameraPose.entry(2, 0))
        ..normalize();
  final cameraUp =
      Vector3(cameraPose.entry(0, 1), cameraPose.entry(1, 1), cameraPose.entry(2, 1))
        ..normalize();

  final worldDelta = cameraRight * (normDelta.dx * distance * kFov) -
      cameraUp * (normDelta.dy * distance * kFov);

  final anchorRotation = anchorPose.getRotation()..invert();
  return anchorRotation.transformed(worldDelta);
}
