package vn.mangodemo.mango_offline

import android.graphics.BitmapFactory
import android.os.Debug
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MultiObjectBenchmarkTest {
    @Test fun boundedSceneBenchmarkRecordsActualObjectsWithoutCameraJpegWrites() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val records = mutableListOf<Map<String, Any>>()
        NativeInferenceEngine(context).use { engine ->
            engine.prepare(multiObject = true)
            for (count in listOf(1, 2, 4, 8)) {
                val bitmap = assets.open("multi/scene_$count.png").use { BitmapFactory.decodeStream(it) }
                assertNotNull(bitmap)
                try {
                    val before = context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() }
                    val timing = mutableListOf<Double>(); val modelTiming = mutableListOf<Double>()
                    val detectorTiming = mutableListOf<Double>(); val classifierTiming = mutableListOf<Double>()
                    var actualCount = -1
                    val pssStart = Debug.getPss()/1024.0
                    for (iteration in 0 until 15) {
                        val result = engine.analyzeCameraBitmap(bitmap, SystemClock.elapsedRealtimeNanos(), multiObject = true)
                        assertFalse(result.containsKey("previewPath"))
                        actualCount = (result["objects"] as List<*>).size
                        assertTrue(actualCount in 0..8)
                        if (iteration >= 3) {
                            timing.add(result["elapsedMs"] as Double); modelTiming.add(result["modelMs"] as Double)
                            detectorTiming.add(result["detectorMs"] as Double); classifierTiming.add(result["classificationMs"] as Double)
                        }
                    }
                    val after = context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() }
                    assertEquals("Live pipeline wrote JPEGs", before, after)
                    fun percentile(values: List<Double>, fraction: Double) = values.sorted()[kotlin.math.ceil((values.size-1)*fraction).toInt()]
                    records.add(mapOf("syntheticGroundTruthObjects" to count, "actualDetectedObjects" to actualCount,
                        "samples" to timing.size, "warmupExcluded" to 3,
                        "pipelineP50Ms" to percentile(timing,.5), "pipelineP95Ms" to percentile(timing,.95),
                        "modelP50Ms" to percentile(modelTiming,.5), "detectorP50Ms" to percentile(detectorTiming,.5),
                        "classificationP50Ms" to percentile(classifierTiming,.5),
                        "pssStartMb" to pssStart, "pssEndMb" to Debug.getPss()/1024.0))
                } finally { bitmap?.recycle() }
            }
        }
        java.io.File(context.filesDir, "multi_object_benchmark.json").writeText(JSONObject(mapOf(
            "device" to android.os.Build.MODEL, "abi" to android.os.Build.SUPPORTED_ABIS.first(),
            "synthetic" to true, "physicalPhone" to false, "records" to records)).toString(2))
    }
}
