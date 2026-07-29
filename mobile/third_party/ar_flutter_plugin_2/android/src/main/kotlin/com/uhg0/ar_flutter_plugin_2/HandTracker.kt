package com.uhg0.ar_flutter_plugin_2

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.hypot
import kotlin.math.max

/**
 * Patch 6: runs MediaPipe Hand Landmarker on ARCore camera frames and reports a distilled
 * gesture payload (per hand: pinch ratio + pinch midpoint in view-normalized coordinates).
 *
 * The image->view mapping (rotation + aspect-fill crop, incl. the landscape lock) is captured
 * per frame from Frame.transformCoordinates2d, so consumers never deal with orientation math.
 */
class HandTracker(
    private val context: Context,
    private val onGesture: (Map<String, Any>) -> Unit,
) {
    private val TAG = "HandTracker"

    private var handLandmarker: HandLandmarker? = null
    private var workerThread: HandlerThread? = null
    private var workerHandler: Handler? = null

    private val inFlight = AtomicBoolean(false)
    @Volatile private var running = false
    @Volatile private var loggedFirstResult = false
    private var lastSubmitMs = 0L
    private var lastTimestampMs = 0L
    private val jpegStream = ByteArrayOutputStream()

    // Affine mapping image-normalized -> view-normalized, captured with each submitted frame:
    // view = origin + u * imageX + v * imageY
    private data class ViewTransform(
        val ox: Float, val oy: Float,
        val ux: Float, val uy: Float,
        val vx: Float, val vy: Float,
    )

    @Volatile private var pendingTransform: ViewTransform? = null
    @Volatile private var pendingImageAspect: Float = 1f

    private companion object {
        const val MIN_INTERVAL_MS = 66L // ~15 Hz
        const val MAX_DIMENSION = 480
        const val LM_WRIST = 0
        const val LM_THUMB_TIP = 4
        const val LM_INDEX_TIP = 8
        const val LM_MIDDLE_MCP = 9
    }

    /** Lazily initializes the landmarker. Returns false if the model cannot be loaded. */
    fun start(): Boolean {
        if (running) return true
        return try {
            val thread = HandlerThread("hand-tracker").also { it.start() }
            workerThread = thread
            workerHandler = Handler(thread.looper)

            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath("hand_landmarker.task")
                        .build(),
                )
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setNumHands(2)
                .setResultListener { result, _ -> onResult(result) }
                .setErrorListener { e ->
                    Log.e(TAG, "Hand landmarker error", e)
                    inFlight.set(false)
                }
                .build()
            handLandmarker = HandLandmarker.createFromOptions(context, options)
            running = true
            Log.i(TAG, "Hand landmarker initialized (model=hand_landmarker.task)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize hand landmarker", e)
            close()
            false
        }
    }

    /** Called from the render thread with the current ARCore frame. Cheap unless due. */
    fun maybeDetect(frame: Frame) {
        if (!running) return
        val now = SystemClock.uptimeMillis()
        if (now - lastSubmitMs < MIN_INTERVAL_MS) return
        if (!inFlight.compareAndSet(false, true)) return

        try {
            // Capture the image->view mapping while the frame is valid.
            val src = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)
            val dst = FloatArray(6)
            frame.transformCoordinates2d(
                Coordinates2d.IMAGE_NORMALIZED, src,
                Coordinates2d.VIEW_NORMALIZED, dst,
            )
            pendingTransform = ViewTransform(
                ox = dst[0], oy = dst[1],
                ux = dst[2] - dst[0], uy = dst[3] - dst[1],
                vx = dst[4] - dst[0], vy = dst[5] - dst[1],
            )

            val image = frame.acquireCameraImage()
            lastSubmitMs = now
            pendingImageAspect = image.width.toFloat() / image.height.toFloat()
            workerHandler?.post { convertAndDetect(image, now) } ?: run {
                image.close()
                inFlight.set(false)
            }
        } catch (e: Exception) {
            // NotYetAvailableException and friends: try again next frame.
            inFlight.set(false)
        }
    }

    private fun convertAndDetect(image: Image, timestampMs: Long) {
        try {
            val bitmap = yuvToDownscaledBitmap(image)
            image.close()
            val landmarker = handLandmarker ?: run {
                inFlight.set(false)
                return
            }
            // detectAsync requires strictly increasing timestamps.
            val ts = max(timestampMs, lastTimestampMs + 1)
            lastTimestampMs = ts
            landmarker.detectAsync(BitmapImageBuilder(bitmap).build(), ts)
        } catch (e: Exception) {
            Log.e(TAG, "Frame conversion failed", e)
            try {
                image.close()
            } catch (_: Exception) {
            }
            inFlight.set(false)
        }
    }

    private fun yuvToDownscaledBitmap(image: Image): Bitmap {
        val nv21 = yuv420ToNv21(image)
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
        jpegStream.reset()
        yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 80, jpegStream)
        val jpegBytes = jpegStream.toByteArray()

        var sampleSize = 1
        while (max(image.width, image.height) / (sampleSize * 2) >= MAX_DIMENSION) {
            sampleSize *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        return BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size, opts)
    }

    private fun yuv420ToNv21(image: Image): ByteArray {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val nv21 = ByteArray(ySize + ySize / 2)

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        var pos = 0
        val yBuffer = yPlane.buffer
        if (yPlane.pixelStride == 1 && yPlane.rowStride == width) {
            yBuffer.get(nv21, 0, ySize)
            pos = ySize
        } else {
            for (row in 0 until height) {
                yBuffer.position(row * yPlane.rowStride)
                yBuffer.get(nv21, pos, width)
                pos += width
            }
        }

        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            for (col in 0 until chromaWidth) {
                val vIndex = row * vPlane.rowStride + col * vPlane.pixelStride
                val uIndex = row * uPlane.rowStride + col * uPlane.pixelStride
                nv21[pos++] = vBuffer.get(vIndex)
                nv21[pos++] = uBuffer.get(uIndex)
            }
        }
        return nv21
    }

    private fun onResult(result: HandLandmarkerResult) {
        inFlight.set(false)
        if (!loggedFirstResult) {
            loggedFirstResult = true
            Log.i(TAG, "First landmark result received (hands=${result.landmarks().size})")
        }
        val transform = pendingTransform ?: return
        val aspect = pendingImageAspect

        val hands = mutableListOf<Map<String, Any>>()
        val landmarksPerHand = result.landmarks()
        for ((index, landmarks) in landmarksPerHand.withIndex()) {
            if (landmarks.size <= LM_MIDDLE_MCP) continue

            val thumb = landmarks[LM_THUMB_TIP]
            val indexTip = landmarks[LM_INDEX_TIP]
            val wrist = landmarks[LM_WRIST]
            val middleMcp = landmarks[LM_MIDDLE_MCP]

            // Aspect-correct x so distances are isotropic in image space.
            val pinchDist = hypot(
                (thumb.x() - indexTip.x()) * aspect,
                thumb.y() - indexTip.y(),
            )
            val handSize = hypot(
                (wrist.x() - middleMcp.x()) * aspect,
                wrist.y() - middleMcp.y(),
            )
            val pinchRatio = pinchDist / max(handSize, 1e-4f)

            val midX = (thumb.x() + indexTip.x()) * 0.5f
            val midY = (thumb.y() + indexTip.y()) * 0.5f
            val viewX = transform.ox + transform.ux * midX + transform.vx * midY
            val viewY = transform.oy + transform.uy * midX + transform.vy * midY

            val confidence = result.handedness().getOrNull(index)
                ?.firstOrNull()?.score() ?: 1f

            // All 21 landmarks in view-normalized coordinates, for the debug overlay.
            val landmarkList = landmarks.map { lm ->
                listOf(
                    (transform.ox + transform.ux * lm.x() + transform.vx * lm.y()).toDouble(),
                    (transform.oy + transform.uy * lm.x() + transform.vy * lm.y()).toDouble(),
                )
            }

            hands.add(
                mapOf(
                    "pinchRatio" to pinchRatio.toDouble(),
                    "cx" to viewX.toDouble().coerceIn(0.0, 1.0),
                    "cy" to viewY.toDouble().coerceIn(0.0, 1.0),
                    "confidence" to confidence.toDouble(),
                    "landmarks" to landmarkList,
                ),
            )
        }

        onGesture(
            mapOf(
                "timestampMs" to SystemClock.uptimeMillis(),
                "hands" to hands,
            ),
        )
    }

    fun close() {
        running = false
        try {
            handLandmarker?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing hand landmarker", e)
        }
        handLandmarker = null
        workerThread?.quitSafely()
        workerThread = null
        workerHandler = null
        inFlight.set(false)
    }
}
