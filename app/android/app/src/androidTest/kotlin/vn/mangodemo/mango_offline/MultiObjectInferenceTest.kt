package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.Color
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class MultiObjectInferenceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun sampledVideoReturnsItsOwnSceneObjectsAndTimestamp() {
        val file = File(context.cacheDir, "multi_codec_fixture.mp4")
        InstrumentationRegistry.getInstrumentation().context.assets.open("codec_fixture.mp4")
            .use { input -> file.outputStream().use { input.copyTo(it) } }
        NativeInferenceEngine(context).use { engine ->
            for (timestamp in listOf(0L, 1000L)) {
                val result = engine.analyzeVideoFrame(file.absolutePath, timestamp, multiObject = true)
                assertEquals(timestamp, result["timestampMs"])
                val objects = result["objects"] as List<*>
                assertTrue("Codec sample should contain a detected mango", objects.isNotEmpty())
                assertTrue(objects.size <= 8)
                assertTrue(File(result["previewPath"] as String).isFile)
                assertNull("No global image box in scene contract", result["box"])
            }
        }
    }

    // Catches accidentally using the old whole-frame class/box in scene mode.
    @Test fun blankSceneHasExplicitEmptyObjectsAndNoLegacyBox() {
        NativeInferenceEngine(context).use { engine ->
            val bitmap = Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.BLACK)
                val result = engine.analyzeCameraBitmap(bitmap, SystemClock.elapsedRealtimeNanos(), multiObject = true)
                assertEquals("NO_MANGO", result["status"])
                assertEquals(0, (result["objects"] as List<*>).size)
                assertNull(result["box"])
                assertFalse(result.containsKey("previewPath"))
                assertTrue((result["detectorMs"] as Double) >= 0.0)
            } finally { bitmap.recycle() }
        }
    }

    // Desktop outputs are independent fixtures, not recomputed with Kotlin helpers.
    @Test fun eachDetectedCropAgreesWithIndependentDesktopRuntime() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val fixtures = assets.open("multi/expected.json").bufferedReader().use { JSONObject(it.readText()).getJSONArray("fixtures") }
        val receipts = mutableListOf<Map<String, Any>>()
        NativeInferenceEngine(context).use { engine ->
            for (i in 0 until fixtures.length()) {
                val fixture = fixtures.getJSONObject(i)
                val file = File(context.cacheDir, fixture.getString("filename"))
                assets.open("multi/${fixture.getString("filename")}").use { input -> file.outputStream().use { input.copyTo(it) } }
                val result = engine.analyzeImage(file.absolutePath, multiObject = true)
                val objects = result["objects"] as List<*>
                val expected = fixture.getJSONArray("objects")
                assertEquals("Count ${file.name}", expected.length(), objects.size)
                assertTrue(objects.size <= 8)
                for (j in objects.indices) {
                    val actual = objects[j] as Map<*, *>
                    val want = expected.getJSONObject(j)
                    assertEquals("Class ${file.name} #$j", want.getInt("classId"), actual["classId"])
                    val box = actual["box"] as List<*>
                    val scores = actual["probabilities"] as List<*>
                    for (k in 0..3) assertEquals(want.getJSONArray("box").getDouble(k), box[k] as Double, .003)
                    for (k in 0..4) assertEquals(want.getJSONArray("probabilities").getDouble(k), scores[k] as Double, 1e-4)
                    assertEquals(want.getDouble("detectionScore"), actual["detectionScore"] as Double, 1e-4)
                    assertTrue(actual["status"] in setOf("OK", "UNCERTAIN"))
                }
                assertTrue(File(result["previewPath"] as String).isFile)
                receipts.add(mapOf("fixture" to file.name, "result" to result))
            }
        }
        File(context.filesDir, "multi_object_parity.json").writeText(JSONObject(mapOf("records" to receipts)).toString(2))
    }
}
