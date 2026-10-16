package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class OfflineInferenceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun twentyFiveOriginalImagesAgreeWithHostPreprocessingAndRuntime() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val expected = assets.open("regression/regression_expected.json").bufferedReader().use { JSONObject(it.readText()).getJSONArray("fixtures") }
        val records = mutableListOf<Map<String, Any>>()
        NativeInferenceEngine(context).use { engine ->
            engine.prepare()
            for (i in 0 until expected.length()) {
                val item = expected.getJSONObject(i)
                val file = File(context.cacheDir, "regression.jpg")
                assets.open("regression/${item.getString("filename")}").use { input -> file.outputStream().use { input.copyTo(it) } }
                val actual = engine.analyzeImage(file.absolutePath)
                val p = actual["probabilities"] as List<*>
                val error = (0..4).maxOf { kotlin.math.abs((p[it] as Double) - item.getJSONArray("probabilities").getDouble(it)) }
                records.add(mapOf("filename" to item.getString("filename"), "expectedClass" to item.getInt("class_id"),
                    "actualClass" to actual["classId"]!!, "maxProbabilityError" to error,
                    "elapsedMs" to actual["elapsedMs"]!!, "modelMs" to actual["modelMs"]!!))
            }
        }
        File(context.filesDir, "photo_parity_verification.json").writeText(JSONObject(mapOf("records" to records)).toString(2))
        records.forEach { row ->
            assertEquals("Top-1 mismatch ${row["filename"]}", row["expectedClass"], row["actualClass"])
            assertTrue("Photo preprocessing drift ${row["filename"]}: ${row["maxProbabilityError"]}", (row["maxProbabilityError"] as Double) < 1e-4)
        }
    }

    @Test fun sampledVideoUsesLocalDecoderAndReturnsTimestampedRealInference() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare()
            val file = File(context.cacheDir, "codec_fixture.mp4")
            InstrumentationRegistry.getInstrumentation().context.assets.open("codec_fixture.mp4")
                .use { input -> file.outputStream().use { input.copyTo(it) } }
            val info = engine.videoInfo(file.absolutePath)
            assertEquals(2000L, info["durationMs"])
            for (timestamp in listOf(0L, 1000L)) {
                val result = engine.analyzeVideoFrame(file.absolutePath, timestamp)
                assertEquals(timestamp, result["timestampMs"])
                assertEquals(5, (result["probabilities"] as List<*>).size)
                assertNotNull(result["box"])
                assertTrue(File(result["previewPath"] as String).isFile)
            }
        }
    }

    @Test fun exportedFixtureAgreesWithDesktopRuntime() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare()
            val file = File(context.cacheDir, "parity_fixture.png")
            context.assets.open("parity_fixture.png").use { input -> file.outputStream().use { input.copyTo(it) } }
            val expected = context.assets.open("parity_expected.json").bufferedReader().use { JSONObject(it.readText()) }
            val actual = engine.analyzeImage(file.absolutePath)
            val probabilities = actual["probabilities"] as List<*>
            for (i in 0..4) assertEquals(expected.getJSONArray("probabilities").getDouble(i), probabilities[i] as Double, 2e-4)
            assertEquals("NO_MANGO", actual["status"])
        }
    }

    @Test fun bundledSampleRunsActualModelWithFiniteFiveClassScoresOffline() {
        NativeInferenceEngine(context).use { engine ->
            val prepared = engine.prepare()
            assertEquals(true, prepared["offline"])
            assertTrue((prepared["modelBytes"] as Long) in 1L..50_000_000L)
            val sample = prepared["samplePath"] as String
            val started = System.nanoTime()
            val results = (0..5).map { engine.analyzeImage(sample) }
            results.forEach {
                val p = it["probabilities"] as List<*>
                assertEquals(5, p.size)
                assertEquals(1.0, p.sumOf { score -> (score as Double) }, 1e-5)
                assertTrue(p.all { score -> (score as Double).isFinite() })
                assertTrue(File(it["previewPath"] as String).isFile)
            }
            val receipt = JSONObject(mapOf("device" to android.os.Build.MODEL,
                "abi" to android.os.Build.SUPPORTED_ABIS.first(), "offline" to true,
                "model" to prepared, "results" to results,
                "totalMs" to (System.nanoTime() - started) / 1e6))
            File(context.filesDir, "device_verification.json").writeText(receipt.toString(2))
        }
    }

    @Test fun blankImageDoesNotInventMangoClass() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare()
            val bitmap = Bitmap.createBitmap(320, 640, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.BLACK)
            val file = File(context.cacheDir, "blank.png")
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            val result = engine.analyzeImage(file.absolutePath)
            assertEquals("NO_MANGO", result["status"])
            assertNull(result["box"])
        }
    }

    @Test fun corruptImageReturnsAnExplicitFailure() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare()
            val invalid = File(context.cacheDir, "broken.jpg").apply { writeText("not an image") }
            try {
                engine.analyzeImage(invalid.absolutePath)
                fail("Corrupt input must not produce a prediction")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }
}
