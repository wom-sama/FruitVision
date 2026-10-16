package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.graphics.Matrix
import android.util.Size
import androidx.camera.view.transform.CoordinateTransform
import androidx.camera.view.transform.OutputTransform
import android.os.SystemClock
import androidx.camera.core.ImageInfo
import androidx.camera.core.ImageProxy
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.lang.reflect.Proxy
import java.io.File
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class LiveInferenceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    // Only the external CameraX conversion boundary is faked. Ownership, pixels,
    // transforms and recycling below are exercised on real Android Bitmaps.
    private fun imageProxy(bitmap: Bitmap, crop: Rect, rotation: Int): ImageProxy {
        val info = Proxy.newProxyInstance(ImageInfo::class.java.classLoader,
            arrayOf(ImageInfo::class.java)) { _, method, _ ->
            when (method.name) {
                "getRotationDegrees" -> rotation
                else -> error("Unexpected ImageInfo method: ${method.name}")
            }
        } as ImageInfo
        return Proxy.newProxyInstance(ImageProxy::class.java.classLoader,
            arrayOf(ImageProxy::class.java)) { _, method, _ ->
            when (method.name) {
                "toBitmap" -> bitmap
                "getCropRect" -> crop
                "getImageInfo" -> info
                else -> error("Unexpected ImageProxy method: ${method.name}")
            }
        } as ImageProxy
    }

    @Test fun ownedIdentityCameraFrameTransfersBitmapWithoutPixelCopy() {
        val bitmap = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888)
        bitmap.setPixels(IntArray(12) { 0xFF000000.toInt() or (it + 1) }, 0, 4, 0, 0, 4, 3)
        val frame = CameraFrame.fromProxy(imageProxy(bitmap, Rect(0, 0, 4, 3), 0))
        try {
            assertSame("Converter bitmap must transfer rather than be copied", bitmap, frame.bitmap)
            assertFalse(bitmap.isRecycled)
            val actual = IntArray(12)
            frame.bitmap.getPixels(actual, 0, 4, 0, 0, 4, 3)
            assertArrayEquals(IntArray(12) { it + 1 }, actual.map { it and 255 }.toIntArray())
            val box = frame.toBufferBox(doubleArrayOf(.25, 0.0, .75, 1.0))
            assertEquals(1f, box.left, .001f); assertEquals(0f, box.top, .001f)
            assertEquals(3f, box.right, .001f); assertEquals(3f, box.bottom, .001f)
        } finally { frame.close() }
        assertTrue(bitmap.isRecycled)
    }

    @Test fun borrowedIdentityBitmapSurvivesFrameClose() {
        val source = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888)
        source.setPixel(2, 1, 0xFF123456.toInt())
        try {
            val frame = CameraFrame.fromBitmap(source, Rect(0, 0, 4, 3), 0)
            assertNotSame(source, frame.bitmap)
            assertEquals(0xFF123456.toInt(), frame.bitmap.getPixel(2, 1))
            frame.close()
            assertFalse(source.isRecycled)
            assertEquals(0xFF123456.toInt(), source.getPixel(2, 1))
        } finally { source.recycle() }
    }

    @Test fun ownedRotatedCameraFrameRecyclesOnlyTheSupersededBitmap() {
        val source = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888)
        source.setPixels(IntArray(12) { 0xFF000000.toInt() or (it + 1) }, 0, 4, 0, 0, 4, 3)
        val frame = CameraFrame.fromProxy(imageProxy(source, Rect(1, 0, 4, 2), 90))
        try {
            assertTrue(source.isRecycled)
            assertFalse(frame.bitmap.isRecycled)
            val actual = IntArray(6)
            frame.bitmap.getPixels(actual, 0, 2, 0, 0, 2, 3)
            assertArrayEquals(intArrayOf(6, 2, 7, 3, 8, 4), actual.map { it and 255 }.toIntArray())
        } finally { frame.close() }
        assertTrue(frame.bitmap.isRecycled)
    }

    @Test fun invalidOwnedCameraFrameRecyclesConverterBitmap() {
        val source = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888)
        assertThrows(IllegalArgumentException::class.java) {
            CameraFrame.fromProxy(imageProxy(source, Rect(0, 0, 4, 3), 45))
        }
        assertTrue(source.isRecycled)
    }

    @Test fun pairedIdentityTransferTimingRetainsExactPixels() {
        val width = 640; val height = 480
        val pixels = IntArray(width * height) { 0xFF000000.toInt() or (it and 0xFFFFFF) }
        val actual = IntArray(pixels.size)
        val baseline = mutableListOf<Double>(); val transfer = mutableListOf<Double>()
        for (sample in 0 until 72) {
            // Alternate order to reduce drift; converter allocation/pixel filling,
            // output validation and frame disposal are outside the measured phase.
            for (owned in if (sample % 2 == 0) listOf(false, true) else listOf(true, false)) {
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
                val crop = Rect(0, 0, width, height)
                val proxy = imageProxy(bitmap, crop, 0)
                val began = SystemClock.elapsedRealtimeNanos()
                val frame = if (owned) CameraFrame.fromProxy(proxy) else {
                    // Exact previous owned-camera behavior through borrowed API.
                    try { CameraFrame.fromBitmap(bitmap, crop, 0) }
                    finally { bitmap.recycle() }
                }
                val elapsedMs = (SystemClock.elapsedRealtimeNanos() - began) / 1e6
                try {
                    frame.bitmap.getPixels(actual, 0, width, 0, 0, width, height)
                    assertArrayEquals(pixels, actual)
                    if (sample >= 12) (if (owned) transfer else baseline).add(elapsedMs)
                } finally { frame.close() }
            }
        }
        fun percentile(values: List<Double>, fraction: Double): Double =
            values.sorted()[((values.size - 1) * fraction).toInt()]
        val report = JSONObject().put("scope", "camera_owned_identity_conversion_only_not_AI_FPS")
            .put("width", width).put("height", height).put("warmup_pairs", 12)
            .put("measured_pairs", 60).put("pixel_mismatches", 0)
            .put("avoidable_argb_copy_bytes_per_applicable_frame", width * height * 4)
            .put("legacy_copy_p50_ms", percentile(baseline, .5))
            .put("legacy_copy_p95_ms", percentile(baseline, .95))
            .put("owned_transfer_p50_ms", percentile(transfer, .5))
            .put("owned_transfer_p95_ms", percentile(transfer, .95))
        File(context.cacheDir, "camera_ownership_timing.json").writeText(report.toString(2))
    }
    @Test fun cameraHotPathMatchesPhotoWithoutWritingPreviewFiles() {
        NativeInferenceEngine(context).use { engine ->
            val prepared = engine.prepare()
            val photo = engine.analyzeImage(prepared["samplePath"] as String)
            val bitmap = BitmapFactory.decodeFile(prepared["samplePath"] as String)
            try {
                val before = context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() }
                val live = engine.analyzeCameraBitmap(bitmap, SystemClock.elapsedRealtimeNanos())
                val after = context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() }
                assertEquals(before, after)
                assertFalse(live.containsKey("previewPath"))
                assertEquals(photo["classId"], live["classId"])
                assertEquals(photo["probabilities"], live["probabilities"])
                assertEquals(photo["box"], live["box"])
            } finally { bitmap.recycle() }
        }
    }
    @Test fun cropRotationAndInverseBoxUseTheSamePixelCoordinates() {
        val bitmap = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888)
        bitmap.setPixels(IntArray(12) { 0xFF000000.toInt() or (it + 1) }, 0, 4, 0, 0, 4, 3)
        try {
            for (rotation in listOf(0, 90, 180, 270)) {
                val frame = CameraFrame.fromBitmap(bitmap, Rect(1, 0, 4, 2), rotation)
                try {
                    assertEquals(if (rotation % 180 == 0) 3 else 2, frame.bitmap.width)
                    assertEquals(if (rotation % 180 == 0) 2 else 3, frame.bitmap.height)
                    val entire = frame.toBufferBox(doubleArrayOf(0.0, 0.0, 1.0, 1.0))
                    assertEquals(1f, entire.left, .001f); assertEquals(0f, entire.top, .001f)
                    assertEquals(4f, entire.right, .001f); assertEquals(2f, entire.bottom, .001f)
                    val expected = when(rotation) {
                        0 -> intArrayOf(2,3,4,6,7,8)
                        90 -> intArrayOf(6,2,7,3,8,4)
                        180 -> intArrayOf(8,7,6,4,3,2)
                        else -> intArrayOf(4,8,3,7,2,6)
                    }
                    val actual = IntArray(6)
                    frame.bitmap.getPixels(actual,0,frame.bitmap.width,0,0,frame.bitmap.width,frame.bitmap.height)
                    assertArrayEquals(expected, actual.map { it and 255 }.toIntArray())
                } finally { frame.close() }
            }
        } finally { bitmap.recycle() }
    }
    @Test fun frontMirrorAndPreviewScalingMapTheCorrectSideOfTheBox() {
        val source = OutputTransform(Matrix(), Size(4, 3))
        val mirrored = Matrix().apply { setScale(-100f, 100f); postTranslate(400f, 0f) }
        val target = OutputTransform(mirrored, Size(4, 3))
        val box = android.graphics.RectF(1f, .5f, 2f, 2f)
        CoordinateTransform(source, target).mapRect(box)
        assertEquals(200f, box.left, .001f); assertEquals(400f - 100f, box.right, .001f)
        assertEquals(50f, box.top, .001f); assertEquals(200f, box.bottom, .001f)
    }
}
