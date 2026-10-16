package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Debug
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Diagnostic cost measurements only; these timings are not full-AI throughput. */
@RunWith(AndroidJUnit4::class)
class VideoPresentationCostDeviceTest {
    @Test fun firstAnalysisDoesNotBlockOnMultiSessionProviderSearch() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = context.assets.open("demo_mango.jpg").use { BitmapFactory.decodeStream(it) }
        try {
            NativeInferenceEngine(context).use { engine ->
                engine.prepare(true)
                val start = SystemClock.elapsedRealtimeNanos()
                val first = engine.analyzeCameraBitmap(bitmap, start, true)
                val firstMs = (SystemClock.elapsedRealtimeNanos() - start) / 1e6
                val warm = (0 until 5).map {
                    val began = SystemClock.elapsedRealtimeNanos()
                    engine.analyzeCameraBitmap(bitmap, began, true)
                    (SystemClock.elapsedRealtimeNanos() - began) / 1e6
                }.sorted()[2]
                val report = JSONObject().put("firstAnalysisMs", firstMs)
                    .put("warmMedianMs", warm).put("runtimeTuningMs", first["runtimeTuningMs"])
                    .put("runtimeProvider", first["runtimeProvider"])
                    .put("scope", "Android emulator startup latency, not throughput or phone field proof.")
                File(context.filesDir, "first_analysis_latency.json").writeText(report.toString(2))
                // An analysis may pay normal cold kernels, but must not launch a
                // seconds-long search that cannot be cancelled by the video UI.
                assertTrue("First analysis contains blocking provider search: $report",
                    firstMs < maxOf(2000.0, warm * 12))
            }
        } finally { bitmap.recycle() }
    }

    @Test fun recordsMemoryTelemetryAndJpegCostsSeparatelyFromModelInference() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val values = mutableListOf<Double>()
        repeat(12) {
            val start = SystemClock.elapsedRealtimeNanos()
            assertTrue(Debug.getPss() > 0)
            values.add((SystemClock.elapsedRealtimeNanos() - start) / 1e6)
        }
        val pixels = IntArray(1280 * 720) { index ->
            0xff000000.toInt() or ((index * 13 and 255) shl 16) or
                ((index * 7 and 255) shl 8) or (index * 3 and 255)
        }
        val image = Bitmap.createBitmap(pixels, 1280, 720, Bitmap.Config.ARGB_8888)
        val output = File(context.cacheDir, "presentation_cost.jpg")
        fun jpeg(bitmap: Bitmap): List<Double> = (0 until 12).map {
            val start = SystemClock.elapsedRealtimeNanos()
            output.outputStream().use { stream -> assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)) }
            (SystemClock.elapsedRealtimeNanos() - start) / 1e6
        }
        try {
            val full = jpeg(image)
            val report = JSONObject().put("pssSampleMs", JSONArray(values))
                .put("jpeg1280x720Ms", JSONArray(full))
                .put("scope", "Microbenchmark, emulator, no model inference, not FPS or field accuracy.")
            File(context.filesDir, "video_presentation_cost.json").writeText(report.toString(2))
        } finally { image.recycle(); output.delete() }
    }
}
