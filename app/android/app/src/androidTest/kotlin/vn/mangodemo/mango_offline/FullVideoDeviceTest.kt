package vn.mangodemo.mango_offline

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Preserve the original aspect/codec: the older resized excerpt is not this clip. */
@RunWith(AndroidJUnit4::class)
class FullVideoDeviceTest {
    @Test fun originalUserVideoRecordsEveryFrameWithoutCrossSpeciesDuplicateBoxes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "real_video_full.mp4")
        instrumentation.context.assets.open("fruit_stage/real_video_full.mp4").use { source ->
            input.outputStream().use { source.copyTo(it) }
        }
        val records = mutableListOf<Map<String, Any>>()
        NativeInferenceEngine(context).use { engine ->
            engine.prepare(true)
            val info = engine.videoInfo(input.absolutePath)
            val duration = info["durationMs"] as Long
            for (timestamp in 0L until duration step 500L) {
                val result = engine.analyzeVideoFrame(input.absolutePath, timestamp, true)
                val objects = result["objects"] as List<*>
                assertEquals(timestamp, result["timestampMs"])
                for (i in objects.indices) for (j in i + 1 until objects.size) {
                    val a = (objects[i] as Map<*, *>)["box"] as List<*>
                    val b = (objects[j] as Map<*, *>)["box"] as List<*>
                    fun n(v: Any?) = (v as Number).toDouble()
                    val overlap = maxOf(0.0, minOf(n(a[2]), n(b[2])) - maxOf(n(a[0]), n(b[0]))) *
                        maxOf(0.0, minOf(n(a[3]), n(b[3])) - maxOf(n(a[1]), n(b[1])))
                    val union = (n(a[2])-n(a[0]))*(n(a[3])-n(a[1])) +
                        (n(b[2])-n(b[0]))*(n(b[3])-n(b[1])) - overlap
                    assertTrue("Cross-species duplicate at $timestamp", overlap / union <= .5)
                }
                records.add(mapOf("timestampMs" to timestamp, "objects" to objects,
                    "elapsedMs" to result["elapsedMs"]!!))
            }
            assertEquals(28, records.size)
            File(context.filesDir, "full_video_trace.json").writeText(JSONObject(mapOf(
                "sourceSha256" to "935f8c96e076420b9bc1efefa7c03e6a5814993db6e52d1a33477fce609eacb1",
                "videoInfo" to info, "records" to records)).toString(2))
        }
    }
}
