import 'dart:ui' show Offset;

import 'package:vector_math/vector_math_64.dart';

/// Maps a view-normalized drag delta to an anchor-local translation.
///
/// The object moves in the camera-facing plane at its current distance:
/// screen-right maps to the camera's right vector and screen-down to the
/// camera's negative up vector, scaled by distance and [kFov]
/// (approximately 2*tan(horizontalFov/2); tuned constant since the plugin
/// exposes no camera intrinsics).
///
/// [normDelta] is normalized per axis — dx by view width, dy by view height —
/// which is what both input paths produce (touch divides by the view's own
/// dimensions, and the plugin reports hand centroids as `VIEW_NORMALIZED`).
/// [kFov] calibrates the *horizontal* field of view, so dy is additionally
/// divided by [viewAspect] (width/height); without that, vertical drag
/// overshoots the finger by exactly the aspect ratio — 2.2x on this
/// landscape-locked app — and diagonal drags curve.
Vector3 computeAnchorLocalDelta({
  required Matrix4 cameraPose,
  required Matrix4 anchorPose,
  required Offset normDelta,
  required double distance,
  required double viewAspect,
  double kFov = 1.4,
}) {
  final cameraRight =
      Vector3(cameraPose.entry(0, 0), cameraPose.entry(1, 0), cameraPose.entry(2, 0))
        ..normalize();
  final cameraUp =
      Vector3(cameraPose.entry(0, 1), cameraPose.entry(1, 1), cameraPose.entry(2, 1))
        ..normalize();

  final worldDelta = cameraRight * (normDelta.dx * distance * kFov) -
      cameraUp * (normDelta.dy * distance * kFov / viewAspect);

  final anchorRotation = anchorPose.getRotation()..invert();
  return anchorRotation.transformed(worldDelta);
}
