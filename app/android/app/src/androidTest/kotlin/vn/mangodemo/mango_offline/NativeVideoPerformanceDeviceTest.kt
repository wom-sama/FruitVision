package vn.mangodemo.mango_offline

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Software/throughput measurement only. This does not use the clip for model selection. */
@RunWith(AndroidJUnit4::class)
class NativeVideoPerformanceDeviceTest {
    @Test fun fullVideoInferenceProcessesEveryFrameAndReportsActualThroughput() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val expected = requireNotNull(arguments.getString("expectedFrames")).toInt()
        require(expected in 1..18000)
        val tag = requireNotNull(arguments.getString("measurementTag"))
        require(tag.matches(Regex("[a-zA-Z0-9_]{1,40}")))
        val video = File(instrumentation.targetContext.cacheDir, "inference_benchmark.mp4")
        ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand("cat /data/local/tmp/fruit_benchmark.mp4")
        ).use { input -> video.outputStream().use { input.copyTo(it) } }
        val pipelines = mutableListOf<Double>()
        val models = mutableListOf<Double>()
        val decodes = mutableListOf<Double>()
        var last = -1L
        var previewCount = 0
        var detectionObservations = 0
        var provider = ""
        var elapsed = 0.0
        var modelSha = ""
        NativeInferenceEngine(instrumentation.targetContext).use { engine ->
            val prepared = engine.prepare(true)
            modelSha = prepared["detectorModelSha256"] as String
            engine.openVideoSequence(video.absolutePath)
            val start = SystemClock.elapsedRealtimeNanos()
            while (true) {
                val began = SystemClock.elapsedRealtimeNanos()
                val response = engine.nextVideoFrame(video.absolutePath, true)
                if (response["endOfStream"] == true) {
                    assertEquals(expected, response["framesDecoded"])
                    break
                }
                assertEquals(pipelines.size, response["frameIndex"])
                val timestamp = response["timestampMs"] as Long
                assertTrue(timestamp > last)
                last = timestamp
                pipelines.add((SystemClock.elapsedRealtimeNanos() - began) / 1e6)
                models.add((response["modelMs"] as Number).toDouble())
                decodes.add((response["decodeMs"] as Number).toDouble())
                if (response["previewUpdated"] == true) previewCount++
                detectionObservations += (response["objects"] as List<*>).size
                provider = response["runtimeProvider"] as String
            }
            elapsed = (SystemClock.elapsedRealtimeNanos() - start) / 1e9
            engine.closeVideoSequence()
            assertFalse(engine.videoSequenceOpen)
        }
        assertEquals(expected, pipelines.size)
        fun percentile(values: List<Double>, p: Double): Double {
            val sorted = values.drop(5).sorted().ifEmpty { values.sorted() }
            return sorted[((sorted.size - 1) * p).toInt()]
        }
        val report = JSONObject().put("framesProcessed", pipelines.size)
            .put("lastTimestampMs", last).put("elapsedSeconds", elapsed)
            .put("nativeProcessedFps", pipelines.size / elapsed)
            .put("pipelineP50Ms", percentile(pipelines, .5)).put("pipelineP95Ms", percentile(pipelines, .95))
            .put("modelP50Ms", percentile(models, .5)).put("modelP95Ms", percentile(models, .95))
            .put("decodeP50Ms", percentile(decodes, .5)).put("decodeP95Ms", percentile(decodes, .95))
            .put("modelSha256", modelSha).put("runtimeProvider", provider)
            .put("previewCount", previewCount).put("detectionObservations", detectionObservations)
            .put("modelInferenceIncluded", true).put("flutterTrackingAndRenderingIncluded", false)
            .put("framesSampledOrSkipped", 0)
            .put("limitations", "Detection observations are not unique fruit counts or accuracy; no trajectory ground truth. Android emulator is not physical-phone evidence.")
        File(instrumentation.targetContext.filesDir, "pipeline_$tag.json").writeText(report.toString(2))
    }

    @Test fun fullVideoDecodesEveryPresentationFrameWithoutSampling() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val expected = requireNotNull(arguments.getString("expectedFrames")).toInt()
        require(expected in 1..18000)
        val tag = requireNotNull(arguments.getString("measurementTag"))
        require(tag.matches(Regex("[a-zA-Z0-9_]{1,40}")))
        val video = File(instrumentation.targetContext.cacheDir, "codec_benchmark.mp4")
        ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand("cat /data/local/tmp/fruit_benchmark.mp4")
        ).use { input -> video.outputStream().use { input.copyTo(it) } }
        val times = mutableListOf<Double>()
        val start = SystemClock.elapsedRealtimeNanos()
        var last = -1L
        NativeVideoDecoder(video.absolutePath).use { decoder ->
            while (true) {
                val began = SystemClock.elapsedRealtimeNanos()
                val frame = decoder.nextFrame() ?: break
                times.add((SystemClock.elapsedRealtimeNanos() - began) / 1e6)
                frame.use {
                    assertEquals(times.size - 1, it.index)
                    assertTrue(it.timestampUs > last)
                    last = it.timestampUs
                }
            }
            assertEquals(expected, decoder.framesDecoded)
        }
        val elapsed = (SystemClock.elapsedRealtimeNanos() - start) / 1e9
        val sorted = times.drop(5).sorted().ifEmpty { times.sorted() }
        fun percentile(p: Double) = sorted[((sorted.size - 1) * p).toInt()]
        val report = JSONObject().put("framesDecoded", times.size)
            .put("lastTimestampUs", last).put("elapsedSeconds", elapsed)
            .put("decodeFps", times.size / elapsed).put("decodeP50Ms", percentile(.5))
            .put("decodeP95Ms", percentile(.95)).put("modelInferenceIncluded", false)
            .put("platform", "Android emulator, not physical-phone evidence")
        File(instrumentation.targetContext.filesDir, "codec_$tag.json").writeText(report.toString(2))
    }
}
