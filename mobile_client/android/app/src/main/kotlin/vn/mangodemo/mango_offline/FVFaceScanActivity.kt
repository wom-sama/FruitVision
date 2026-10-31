@file:Suppress("DEPRECATION")

package vn.mangodemo.mango_offline

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.YuvImage
import android.hardware.Camera
import android.media.FaceDetector
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min

/** Embedded photo framing only. It does not prove identity or liveness.
 * Server face matching and the existing email challenge remain mandatory.
 * Uses the Android platform detector, not an APK recognition model or external camera app.
 */
class FVFaceScanActivity : Activity(), TextureView.SurfaceTextureListener {
    private lateinit var preview: TextureView
    private lateinit var previewHost: FrameLayout
    private lateinit var status: TextView
    private lateinit var guide: Guide
    private val worker = Executors.newSingleThreadExecutor()
    private val processing = AtomicBoolean(false)
    private val generation = AtomicInteger(0)
    private val gate = FVFaceFramingGate()
    private var camera: Camera? = null
    @Volatile private var resumed = false
    private var delivered = false
    private var lastFrameAt = 0L
    private var scanStartedAt = 0L
    private var previewWidth = 0
    private var previewHeight = 0
    private var imageRotation = 0
    private var lastDisplayRotation = -1
    private val permissionRequest = 4521

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(16, 28, 23))
            setPadding(dp(20), dp(18), dp(20), dp(18))
        }
        root.addView(TextView(this).apply {
            text = "Quét khuôn mặt"
            textSize = 24f
            setTextColor(Color.WHITE)
        })
        root.addView(TextView(this).apply {
            text = "Nhìn thẳng và giữ yên. Máy sẽ tự chụp."
            textSize = 16f
            setTextColor(Color.rgb(211, 224, 215))
            setPadding(0, dp(8), 0, dp(12))
        })
        previewHost = FrameLayout(this)
        preview = TextureView(this).apply { surfaceTextureListener = this@FVFaceScanActivity }
        previewHost.addView(preview, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        guide = Guide(this)
        previewHost.addView(guide, FrameLayout.LayoutParams(-1, -1))
        root.addView(previewHost, LinearLayout.LayoutParams(-1, 0, 1f))
        status = TextView(this).apply {
            text = "Đưa một khuôn mặt vào khung"
            textSize = 17f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setPadding(0, dp(14), 0, dp(8))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        root.addView(status)
        root.addView(Button(this).apply {
            text = "Hủy quét"
            setOnClickListener { finish() }
        })
        setContentView(root)
        previewHost.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitPreview() }
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), permissionRequest)
        } else openCamera()
    }

    override fun onPause() {
        resumed = false
        releaseCamera()
        super.onPause()
    }

    override fun onDestroy() {
        releaseCamera()
        worker.shutdown()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequest) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) openCamera()
            else fail("Cần quyền máy ảnh để tự quét khuôn mặt.")
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) = openCamera()
    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = fitPreview()
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        releaseCamera()
        return true
    }

    private fun openCamera() {
        if (!resumed || delivered || isFinishing || camera != null || !preview.isAvailable ||
            checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
        try {
            val info = Camera.CameraInfo()
            val id = (0 until Camera.getNumberOfCameras()).firstOrNull {
                Camera.getCameraInfo(it, info)
                info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT
            } ?: return fail("Thiết bị không có máy ảnh trước.")
            Camera.getCameraInfo(id, info)
            val opened = Camera.open(id)
            camera = opened
            val params = opened.parameters
            val sizes = params.supportedPreviewSizes.orEmpty().filter {
                it.width % 2 == 0 && it.height % 2 == 0 && it.width >= 320 && it.height >= 240 &&
                    it.width <= 1280 && it.height <= 960
            }
            val size = sizes.minByOrNull { abs(it.width * it.height - 640 * 480) }
                ?: return fail("Máy ảnh chưa hỗ trợ định dạng tự quét.")
            require(params.supportedPreviewFormats.contains(ImageFormat.NV21))
            previewWidth = size.width
            previewHeight = size.height
            params.setPreviewSize(size.width, size.height)
            params.previewFormat = ImageFormat.NV21
            if (params.supportedFocusModes?.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE) == true)
                params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
            opened.parameters = params
            val degrees = when (windowManager.defaultDisplay.rotation) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
            lastDisplayRotation = windowManager.defaultDisplay.rotation
            imageRotation = (info.orientation + degrees) % 360
            opened.setDisplayOrientation((360 - imageRotation) % 360)
            opened.setPreviewTexture(preview.surfaceTexture)
            val lease = generation.incrementAndGet()
            synchronized(gate) { gate.reset() }
            lastFrameAt = 0
            scanStartedAt = SystemClock.elapsedRealtime()
            opened.setPreviewCallbackWithBuffer { data, owner -> frame(data, owner, lease) }
            repeat(2) { opened.addCallbackBuffer(ByteArray(size.width * size.height * 3 / 2)) }
            fitPreview()
            opened.startPreview()
        } catch (_: Exception) {
            fail("Không mở được máy ảnh trước. Hãy đóng ứng dụng dùng camera rồi thử lại.")
        }
    }

    private fun fitPreview() {
        if (previewWidth == 0 || previewHost.width == 0 || previewHost.height == 0) return
        val swapped = imageRotation % 180 != 0
        val width = if (swapped) previewHeight else previewWidth
        val height = if (swapped) previewWidth else previewHeight
        val scale = min(previewHost.width.toFloat() / width, previewHost.height.toFloat() / height)
        val fittedWidth = (width * scale).toInt().coerceAtLeast(1)
        val fittedHeight = (height * scale).toInt().coerceAtLeast(1)
        val current = preview.layoutParams
        if (current.width != fittedWidth || current.height != fittedHeight)
            preview.layoutParams = FrameLayout.LayoutParams(fittedWidth, fittedHeight, Gravity.CENTER)
        guide.imageBounds = RectF((previewHost.width - fittedWidth) / 2f, (previewHost.height - fittedHeight) / 2f,
            (previewHost.width + fittedWidth) / 2f, (previewHost.height + fittedHeight) / 2f)
        guide.invalidate()
    }

    private fun frame(data: ByteArray?, owner: Camera, lease: Int) {
        val now = SystemClock.elapsedRealtime()
        if (data == null) return
        if (!resumed || delivered || generation.get() != lease || now - lastFrameAt < 300 ||
            !processing.compareAndSet(false, true)) {
            if (camera === owner) owner.addCallbackBuffer(data)
            return
        }
        if (lastDisplayRotation != windowManager.defaultDisplay.rotation) {
            processing.set(false)
            releaseCamera()
            openCamera()
            return
        }
        lastFrameAt = now
        val copied = data.copyOf()
        owner.addCallbackBuffer(data)
        val width = previewWidth
        val height = previewHeight
        val rotation = imageRotation
        worker.execute {
            var decoded: Bitmap? = null
            var upright: Bitmap? = null
            var detectorBitmap: Bitmap? = null
            var output: File? = null
            try {
                val stream = ByteArrayOutputStream()
                require(YuvImage(copied, ImageFormat.NV21, width, height, null)
                    .compressToJpeg(Rect(0, 0, width, height), 90, stream))
                val decodedImage = BitmapFactory.decodeByteArray(stream.toByteArray(), 0, stream.size())
                    ?: error("Invalid camera frame")
                decoded = decodedImage
                val image = if (rotation == 0) decodedImage else Bitmap.createBitmap(decodedImage, 0, 0, decodedImage.width,
                    decodedImage.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
                upright = image
                // The OS detector requires RGB_565 and an even width. Preview dimensions are bounded/even.
                val detectorImage = image.copy(Bitmap.Config.RGB_565, false) ?: error("Invalid detector frame")
                detectorBitmap = detectorImage
                val found = arrayOfNulls<FaceDetector.Face>(3)
                val count = FaceDetector(detectorImage.width, detectorImage.height, 3).findFaces(detectorImage, found)
                val observations = found.take(count).filterNotNull().map { face ->
                    val point = PointF()
                    face.getMidPoint(point)
                    FVFaceObservation(point.x / image.width, point.y / image.height,
                        face.eyesDistance() / min(image.width, image.height),
                        face.confidence(), face.pose(FaceDetector.Face.EULER_Z))
                }
                val progress = synchronized(gate) {
                    if (generation.get() != lease) return@execute
                    gate.observe(observations, now)
                }
                if (progress.ready && resumed && generation.get() == lease) {
                    val directory = File(cacheDir, "fv_capture")
                    check(directory.isDirectory || directory.mkdirs())
                    val captured = File.createTempFile("face_scan_", ".jpg", directory)
                    output = captured
                    captured.outputStream().use { check(image.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
                    require(captured.length() in 1..2L * 1024 * 1024)
                }
                val completed = output
                runOnUiThread {
                    if (!resumed || isFinishing || delivered || generation.get() != lease) {
                        completed?.delete()
                    } else if (completed != null) {
                        delivered = true
                        releaseCamera()
                        setResult(RESULT_OK, Intent().putExtra("path", completed.absolutePath))
                        finish()
                    } else {
                        val message = if (now - scanStartedAt > 30_000 && !progress.ready)
                            "Chưa chụp được. Tăng ánh sáng, bỏ kính che mắt và nhìn thẳng."
                        else progress.message
                        if (status.text.toString() != message) status.text = message
                        guide.progress = progress.fraction
                        guide.invalidate()
                    }
                }
                output = null // UI owns the completed temporary file until delivery/cancellation.
            } catch (_: Exception) {
                output?.delete()
                synchronized(gate) { gate.reset() }
                runOnUiThread {
                    if (resumed && generation.get() == lease && !isFinishing)
                        status.text = "Chưa đọc được khuôn mặt. Giữ máy ổn định và tăng ánh sáng."
                }
            } finally {
                detectorBitmap?.recycle()
                if (upright !== decoded) upright?.recycle()
                decoded?.recycle()
                processing.set(false)
            }
        }
    }

    private fun releaseCamera() {
        generation.incrementAndGet()
        val opened = camera
        camera = null
        if (opened != null) {
            try { opened.setPreviewCallbackWithBuffer(null); opened.stopPreview() } catch (_: RuntimeException) { }
            opened.release()
        }
        synchronized(gate) { gate.reset() }
    }

    private fun fail(message: String) {
        releaseCamera()
        setResult(RESULT_CANCELED, Intent().putExtra("error", message))
        finish()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private class Guide(context: android.content.Context) : View(context) {
        var imageBounds = RectF()
        var progress = 0f
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 4f }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val bounds = if (imageBounds.isEmpty) RectF(0f, 0f, width.toFloat(), height.toFloat()) else imageBounds
            val half = min(bounds.width() * .32f, bounds.height() * .27f)
            val oval = RectF(bounds.centerX() - half, bounds.centerY() - half * 1.25f,
                bounds.centerX() + half, bounds.centerY() + half * 1.25f)
            paint.color = Color.argb(180, 255, 255, 255)
            canvas.drawOval(oval, paint)
            paint.color = Color.rgb(153, 227, 174)
            canvas.drawArc(oval, -90f, 360f * progress.coerceIn(0f, 1f), false, paint)
        }
    }
}

internal data class FVFaceObservation(val x: Float, val y: Float, val eyeRatio: Float,
    val confidence: Float, val roll: Float)
internal data class FVFaceFramingProgress(val message: String, val fraction: Float = 0f, val ready: Boolean = false)

/** Pure framing policy, suitable for host unit tests. No identity/anti-spoof assertions. */
internal class FVFaceFramingGate {
    private var anchor: FVFaceObservation? = null
    private var since = 0L
    private var last = 0L
    private var frames = 0
    fun reset() { anchor = null; since = 0L; last = 0L; frames = 0 }
    fun observe(faces: List<FVFaceObservation>, at: Long): FVFaceFramingProgress {
        fun reject(message: String): FVFaceFramingProgress { reset(); return FVFaceFramingProgress(message) }
        if (faces.isEmpty()) return reject("Đưa một khuôn mặt vào khung")
        if (faces.size != 1) return reject("Chỉ một người trong khung hình")
        val face = faces.single()
        if (!listOf(face.x, face.y, face.eyeRatio, face.confidence, face.roll).all { it.isFinite() })
            return reject("Nhìn thẳng vào máy ảnh")
        if (face.confidence < .4f) return reject("Tăng ánh sáng và để rõ hai mắt")
        if (face.eyeRatio < .12f) return reject("Đưa máy gần hơn")
        if (face.eyeRatio > .32f) return reject("Đưa máy xa hơn")
        // OS midpoint is between the eyes, above the visual center of the face.
        if (abs(face.x - .5f) > .13f || face.y !in .28f.. .58f) return reject("Đưa khuôn mặt vào giữa khung")
        if (abs(face.roll) > 15f) return reject("Giữ đầu thẳng")
        val previous = anchor
        val resetHold = previous == null || at < last || at - last > 1400 ||
            hypot(face.x - previous.x, face.y - previous.y) > .035f ||
            abs(face.eyeRatio / previous.eyeRatio - 1f) > .1f
        if (resetHold) { anchor = face; since = at; frames = 0 }
        last = at
        frames++
        val elapsed = at - since
        val fraction = min(frames / 3f, elapsed / 700f).coerceIn(0f, 1f)
        val ready = frames >= 3 && elapsed >= 700
        return FVFaceFramingProgress(if (ready) "Đang chụp…" else "Giữ yên một chút…", fraction, ready)
    }
}
