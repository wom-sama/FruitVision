package vn.mangodemo.mango_offline

import android.graphics.BitmapFactory
import android.graphics.RectF
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class PreprocessingDeviceTest {
    @Test fun pairedResizeAndPackingKeepExactPixelsAndMeasureCost() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.context.assets.open("fruit_stage/actual_source_0.png").use { BitmapFactory.decodeStream(it) }
        val source = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(source, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val width = bitmap.width; val height = bitmap.height; bitmap.recycle()
        val scale = 480.0 / maxOf(width, height)
        val w = maxOf(1, (width * scale).toInt()); val h = maxOf(1, (height * scale).toInt())
        val reusable = ImageResampler.Reusable()
        val baseline = LiveSamples(60); val candidate = LiveSamples(60)
        for (round in 0 until 70) {
            // Reverse order each round; varying pixels catches a stale cached frame.
            source[round % source.size] = 0xff123456.toInt() + round
            var expected: IntArray? = null; var actual: IntArray? = null
            for (kind in if (round % 2 == 0) listOf(0, 1) else listOf(1, 0)) {
                val began = SystemClock.elapsedRealtimeNanos()
                if (kind == 0) expected = ImageResampler.resizeRgb(source, width, height, w, h)
                else actual = reusable.resizeRgb(source, width, height, w, h)
                val elapsed = (SystemClock.elapsedRealtimeNanos() - began) / 1e6
                if (round >= 10) (if (kind == 0) baseline else candidate).add(elapsed)
            }
            assertArrayEquals(expected, actual)
        }
        val canvas = IntArray(480 * 480) { source[it % source.size] }
        val direct = ByteBuffer.allocateDirect(3 * canvas.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        val bulk = FloatArray(3 * canvas.size)
        val individualTime = LiveSamples(60); val bulkTime = LiveSamples(60)
        for (round in 0 until 70) {
            for (kind in if (round % 2 == 0) listOf(0, 1) else listOf(1, 0)) {
                val began = SystemClock.elapsedRealtimeNanos()
                direct.clear()
                if (kind == 0) {
                    for (channel in 0..2) for (pixel in canvas) direct.put(((pixel shr (16 - channel * 8)) and 255) / 255f)
                } else {
                    for (i in canvas.indices) {
                        val pixel = canvas[i]
                        bulk[i] = ((pixel ushr 16) and 255) / 255f
                        bulk[canvas.size + i] = ((pixel ushr 8) and 255) / 255f
                        bulk[2 * canvas.size + i] = (pixel and 255) / 255f
                    }
                    direct.put(bulk)
                }
                direct.flip()
                val elapsed = (SystemClock.elapsedRealtimeNanos() - began) / 1e6
                if (round >= 10) (if (kind == 0) individualTime else bulkTime).add(elapsed)
                for (i in 0 until direct.remaining()) {
                    val expected = ((canvas[i % canvas.size] shr (16 - i / canvas.size * 8)) and 255) / 255f
                    assertEquals(expected, direct.get(i), 0f)
                }
            }
        }
        val report = mapOf("samples" to 60, "warmups" to 10, "width" to width, "height" to height,
            "baseline_resize_p50_ms" to baseline.percentile(.5), "reusable_resize_p50_ms" to candidate.percentile(.5),
            "baseline_resize_p95_ms" to baseline.percentile(.95), "reusable_resize_p95_ms" to candidate.percentile(.95),
            "individual_pack_p50_ms" to individualTime.percentile(.5), "bulk_pack_p50_ms" to bulkTime.percentile(.5),
            "individual_pack_p95_ms" to individualTime.percentile(.95), "bulk_pack_p95_ms" to bulkTime.percentile(.95),
            "pixels_and_tensor_exact" to true)
        File(instrumentation.targetContext.filesDir, "preprocessing_paired.json").writeText(JSONObject(report).toString(2))
    }

    @Test fun denseSceneDoesNotCrashOverlayAboveEightFruit() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = LivePreviewView(instrumentation.targetContext)
            view.showBoxes(List(64) { LivePreviewView.Box(RectF(10f, 10f, 30f, 30f), "#${it+1}", 0) })
            view.clearBox()
            assertThrows(IllegalArgumentException::class.java) {
                view.showBoxes(List(65) { LivePreviewView.Box(RectF(10f,10f,30f,30f),"#${it+1}",0) })
            }
        }
    }
}
