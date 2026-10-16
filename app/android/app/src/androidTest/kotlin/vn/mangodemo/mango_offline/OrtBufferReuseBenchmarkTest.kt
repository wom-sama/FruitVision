package vn.mangodemo.mango_offline

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.security.MessageDigest

/**
 * Measurement only: no app runtime change or provider search. Catches stale cached inputs,
 * wrong output shape/type, getter-vs-pinned value differences and premature pinned closes.
 * ORT documents direct-buffer reuse and caller ownership of pinned outputs at:
 * https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/java/src/main/java/ai/onnxruntime/OnnxTensor.java
 * https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/java/src/main/java/ai/onnxruntime/OrtSession.java
 */
@RunWith(AndroidJUnit4::class)
class OrtBufferReuseBenchmarkTest {
    @Test fun reusableBuffersPreserveEveryRawOutputAndMeasureBothPairOrders() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val environment = OrtEnvironment.getEnvironment() // Shared environment is not test-owned.
        val model = instrumentation.targetContext.assets.open("mango_detector.onnx").use { it.readBytes() }
        val modelSha = sha256(model)
        assertEquals("Probe must use the shipped Tiny480 INT8 graph", SHIPPED_SHA, modelSha)
        val report = JSONObject()
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(2)
            options.setInterOpNumThreads(1)
            options.setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            options.addConfigEntry("session.intra_op.allow_spinning", "0")
            options.addConfigEntry("session.inter_op.allow_spinning", "0")
            // No execution provider is added: both paths use this one CPU session.
            environment.createSession(model, options).use { session ->
                assertEquals(setOf("image"), session.inputNames)
                val inputInfo = session.inputInfo.getValue("image").info as TensorInfo
                assertEquals(OnnxJavaType.FLOAT, inputInfo.type)
                assertArrayEquals(longArrayOf(1, 3, 480, 480), inputInfo.shape)
                val specs = checkedOutputSpecs(session)
                val photos = (0..5).map { index ->
                    val bitmap = instrumentation.context.assets.open("fruit_stage/actual_source_$index.png")
                        .use { requireNotNull(BitmapFactory.decodeStream(it)) }
                    try {
                        val source = IntArray(bitmap.width * bitmap.height)
                        bitmap.getPixels(source, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                        val target = inputInfo.shape[2].toInt()
                        val scale = target.toDouble() / maxOf(bitmap.width, bitmap.height)
                        val w = maxOf(1, (bitmap.width * scale).toInt())
                        val h = maxOf(1, (bitmap.height * scale).toInt())
                        val resized = ImageResampler.resizeRgb(source, bitmap.width, bitmap.height, w, h)
                        val pixels = IntArray(target * target) { 0xff808080.toInt() }
                        for (row in 0 until h) resized.copyInto(pixels,
                            (row + (target - h) / 2) * target + (target - w) / 2, row * w, (row + 1) * w)
                        FloatArray(elementCount(inputInfo.shape)).also { values ->
                            for (channel in 0..2) for (i in pixels.indices)
                                values[channel * pixels.size + i] = ((pixels[i] ushr (16 - channel * 8)) and 255) / 255f
                        }
                    } finally { bitmap.recycle() }
                }
                TensorOwner().use { tensors ->
                    val inputBuffer = directBytes(elementCount(inputInfo.shape), 4).asFloatBuffer()
                    val cachedInput = tensors.own(OnnxTensor.createTensor(environment, inputBuffer, inputInfo.shape))
                    assertFalse("Direct input must be borrowed, not copied", cachedInput.ownsBuffer())
                    val cachedInputs = mapOf("image" to cachedInput)
                    val pinned = specs.associate { spec ->
                        val bytes = directBytes(spec.elements, if (spec.type == OnnxJavaType.FLOAT) 4 else 8)
                        val value = if (spec.type == OnnxJavaType.FLOAT) {
                            val buffer = bytes.asFloatBuffer()
                            Pinned(tensors.own(OnnxTensor.createTensor(environment, buffer, spec.shape)), buffer, null)
                        } else {
                            val buffer = bytes.asLongBuffer()
                            Pinned(tensors.own(OnnxTensor.createTensor(environment, buffer, spec.shape)), null, buffer)
                        }
                        assertFalse("Pinned ${spec.name} must borrow its direct buffer", value.tensor.ownsBuffer())
                        spec.name to value
                    }
                    val pinnedTensors = pinned.mapValues { it.value.tensor }
                    val cachedArrays = OutputArrays.allocate(specs)
                    val legacyArrays = OutputArrays.allocate(specs)

                    fun sample(photo: FloatArray, reusable: Boolean): Sample {
                        var runNs = 0L
                        var extractionNs = 0L
                        var verificationNs = 0L
                        lateinit var values: OutputArrays
                        val started = SystemClock.elapsedRealtimeNanos()
                        // Same direct input allocation and pixel copy, used strictly sequentially.
                        inputBuffer.clear()
                        inputBuffer.put(photo)
                        inputBuffer.flip()
                        if (reusable) pinned.values.forEach { it.rewind() }
                        fun consume(input: OnnxTensor) {
                            val inputs = if (reusable) cachedInputs else mapOf("image" to input)
                            val runStarted = SystemClock.elapsedRealtimeNanos()
                            val result = if (reusable) session.run(inputs, pinnedTensors) else session.run(inputs)
                            runNs = SystemClock.elapsedRealtimeNanos() - runStarted
                            result.use {
                                val extractionStarted = SystemClock.elapsedRealtimeNanos()
                                // Reuse the test's holder maps for both paths so only the legacy
                                // primitive arrays/getter buffers are freshly allocated per run.
                                values = if (reusable) cachedArrays else legacyArrays.also { it.replaceArrays(specs) }
                                for (spec in specs) {
                                    if (reusable) pinned.getValue(spec.name).readInto(spec.name, values)
                                    else {
                                        val output = result.get(spec.name).get() as OnnxTensor
                                        if (spec.type == OnnxJavaType.FLOAT)
                                            output.floatBuffer.get(values.floats.getValue(spec.name))
                                        else output.longBuffer.get(values.longs.getValue(spec.name))
                                    }
                                }
                                extractionNs = SystemClock.elapsedRealtimeNanos() - extractionStarted
                                if (reusable) {
                                    val verificationStarted = SystemClock.elapsedRealtimeNanos()
                                    assertEquals(5, result.size())
                                    for (spec in specs) {
                                        assertSame("ORT must return the caller-owned ${spec.name}",
                                            pinned.getValue(spec.name).tensor, result.get(spec.name).get())
                                        pinned.getValue(spec.name).assertMatches(spec.name, values)
                                    }
                                    verificationNs = SystemClock.elapsedRealtimeNanos() - verificationStarted
                                }
                            }
                        }
                        if (reusable) consume(cachedInput)
                        else OnnxTensor.createTensor(environment, inputBuffer, inputInfo.shape).use { consume(it) }
                        // Include input update, wrapper/map construction, run, extraction and closes;
                        // subtract only explicit untimed correctness checks before Result.close().
                        val combinedNs = SystemClock.elapsedRealtimeNanos() - started - verificationNs
                        if (reusable) for (spec in specs) {
                            val output = pinned.getValue(spec.name)
                            assertFalse("Result.close() closed caller-owned ${spec.name}", output.tensor.isClosed)
                            output.assertMatches(spec.name, values)
                        }
                        return Sample(values, runNs / 1e6, extractionNs / 1e6, combinedNs / 1e6)
                    }

                    fun pair(index: Int, legacyFirst: Boolean): Pair<Sample, Sample> {
                        val photo = photos[index % photos.size]
                        val first = sample(photo, reusable = !legacyFirst)
                        val second = sample(photo, reusable = legacyFirst)
                        val legacy = if (legacyFirst) first else second
                        val reusable = if (legacyFirst) second else first
                        assertRawEquals(legacy.values, reusable.values)
                        return legacy to reusable
                    }
                    repeat(12) { pair(it, legacyFirst = it % 2 == 0) }
                    val photoDigests = mutableMapOf<Int, String>()
                    val phases = JSONArray()
                    repeat(2) { phase ->
                        val legacySamples = mutableListOf<Timing>()
                        val reusableSamples = mutableListOf<Timing>()
                        val pairs = JSONArray()
                        repeat(30) { round ->
                            val legacyFirst = (round % 2 == 0) != (phase == 1)
                            val (legacy, reusable) = pair(round, legacyFirst)
                            // Retain timings only; production would release legacy frame arrays.
                            legacySamples.add(legacy.timing())
                            reusableSamples.add(reusable.timing())
                            val photoIndex = round % photos.size
                            if (photoIndex !in photoDigests) photoDigests[photoIndex] = digest(legacy.values)
                            pairs.put(JSONObject().put("round", round).put("photo", photoIndex)
                                .put("first", if (legacyFirst) "legacy" else "reusable")
                                .put("legacy", legacy.timingJson()).put("reusable", reusable.timingJson()))
                        }
                        phases.put(JSONObject().put("phase", if (phase == 0) "alternating" else "reversed_alternating")
                            .put("pairs", pairs).put("legacy", statistics(legacySamples))
                            .put("reusable", statistics(reusableSamples)))
                    }
                    assertEquals(6, photoDigests.size)
                    assertTrue("Photos must produce different outputs so a stale input cannot pass",
                        photoDigests.values.toSet().size > 1)
                    report.put("phases", phases).put("distinctPhotoOutputDigests", photoDigests.values.toSet().size)
                    report.put("outputs", JSONArray(specs.map { spec -> JSONObject()
                        .put("name", spec.name).put("type", spec.type.name)
                        .put("shape", JSONArray(spec.shape.toList())).put("elements", spec.elements) }))
                }
            }
        }
        report.put("modelSha256", modelSha).put("device", android.os.Build.MODEL)
            .put("provider", "CPU").put("intraOpThreads", 2).put("sessions", 1)
            .put("warmupPairs", 12).put("measuredPairsPerPhase", 30).put("photos", 6)
            .put("allFiveRawOutputsBitExact", true).put("pinnedOutputsSurviveResultClose", true)
            .put("enabledInApp", false).put("allocationMeasurementIncluded", false)
            .put("scope", "Combined = direct input update + input tensor/map construction + ORT run + output extraction + result/input closes; explicit parity checks excluded. Photo decode/resize, provider tuning, video/camera conversion, NMS, tracking, Flutter/rendering and file writes excluded.")
            .put("limitations", "Microbenchmark only; no allocation/GC, fruit accuracy, full-video FPS or 30FPS conclusion. Each phase must be assessed separately; no minimum speedup is asserted.")
        instrumentation.sendStatus(0, Bundle().apply {
            putString("ort_buffer_reuse_benchmark", report.toString())
            putString("stream", "\nORT_BUFFER_REUSE_BENCHMARK ${report}\n")
        })
    }

    private data class Spec(val name: String, val type: OnnxJavaType, val shape: LongArray) {
        val elements: Int = elementCount(shape)
    }

    private fun checkedOutputSpecs(session: OrtSession): List<Spec> {
        val expected = linkedMapOf(
            "boxes" to (OnnxJavaType.FLOAT to longArrayOf(1, 4725, 4)),
            "scores" to (OnnxJavaType.FLOAT to longArrayOf(1, 4725)),
            "species_ids" to (OnnxJavaType.INT64 to longArrayOf(1, 4725)),
            "stage_ids" to (OnnxJavaType.INT64 to longArrayOf(1, 4725)),
            "stage_scores" to (OnnxJavaType.FLOAT to longArrayOf(1, 4725, 2)))
        assertEquals(expected.keys, session.outputNames)
        return expected.map { (name, wanted) ->
            val actual = session.outputInfo.getValue(name).info as TensorInfo
            assertEquals("Output type: $name", wanted.first, actual.type)
            assertArrayEquals("Static output shape: $name", wanted.second, actual.shape)
            Spec(name, actual.type, actual.shape.copyOf()) // Allocate from verified runtime dimensions.
        }
    }

    private class OutputArrays(val floats: MutableMap<String, FloatArray>, val longs: MutableMap<String, LongArray>) {
        fun replaceArrays(specs: List<Spec>) {
            for (spec in specs) if (spec.type == OnnxJavaType.FLOAT) floats[spec.name] = FloatArray(spec.elements)
            else longs[spec.name] = LongArray(spec.elements)
        }
        companion object {
            fun allocate(specs: List<Spec>) = OutputArrays(
                linkedMapOf<String, FloatArray>(), linkedMapOf<String, LongArray>()).also { it.replaceArrays(specs) }
        }
    }

    private class Pinned(val tensor: OnnxTensor, val floats: FloatBuffer?, val longs: LongBuffer?) {
        fun rewind() { floats?.clear(); longs?.clear() }
        fun readInto(name: String, destination: OutputArrays) {
            if (floats != null) { floats.clear(); floats.get(destination.floats.getValue(name)); floats.rewind() }
            else {
                val buffer = requireNotNull(longs)
                buffer.clear(); buffer.get(destination.longs.getValue(name)); buffer.rewind()
            }
        }
        fun assertMatches(name: String, expected: OutputArrays) {
            if (floats != null) {
                val view = floats.duplicate().apply { clear() }
                for ((index, value) in expected.floats.getValue(name).withIndex())
                    if (value.toRawBits() != view.get().toRawBits()) fail("Pinned $name differs at $index")
            } else {
                val view = longs!!.duplicate().apply { clear() }
                for ((index, value) in expected.longs.getValue(name).withIndex())
                    if (value != view.get()) fail("Pinned $name differs at $index")
            }
        }
    }

    private class TensorOwner : AutoCloseable {
        private val values = mutableListOf<OnnxTensor>()
        fun own(value: OnnxTensor): OnnxTensor = value.also { values.add(it) }
        override fun close() {
            var failure: Throwable? = null
            for (value in values.asReversed()) try { value.close() } catch (error: Throwable) {
                val previous = failure
                if (previous == null) failure = error else previous.addSuppressed(error)
            }
            failure?.let { throw it }
        }
    }

    private data class Sample(val values: OutputArrays, val runMs: Double, val extractionMs: Double, val combinedMs: Double) {
        fun timing(): Timing = Timing(runMs, extractionMs, combinedMs)
        fun timingJson(): JSONObject = JSONObject().put("runMs", runMs)
            .put("extractionMs", extractionMs).put("combinedMs", combinedMs)
    }

    private data class Timing(val runMs: Double, val extractionMs: Double, val combinedMs: Double)

    private fun statistics(samples: List<Timing>): JSONObject {
        fun percentile(values: List<Double>, fraction: Double): Double {
            val ordered = values.sorted()
            return ordered[((ordered.size - 1) * fraction).toInt()]
        }
        val report = JSONObject().put("samples", samples.size)
        for ((name, values) in listOf("run" to samples.map { it.runMs },
            "extraction" to samples.map { it.extractionMs }, "combined" to samples.map { it.combinedMs })) {
            report.put("${name}P50Ms", percentile(values, .5)).put("${name}P95Ms", percentile(values, .95))
        }
        return report
    }

    private fun assertRawEquals(expected: OutputArrays, actual: OutputArrays) {
        assertEquals(expected.floats.keys, actual.floats.keys)
        assertEquals(expected.longs.keys, actual.longs.keys)
        for ((name, values) in expected.floats) {
            val other = actual.floats.getValue(name)
            assertEquals(values.size, other.size)
            for (index in values.indices) if (values[index].toRawBits() != other[index].toRawBits())
                fail("Raw $name differs at $index: ${values[index]} vs ${other[index]}")
        }
        for ((name, values) in expected.longs) assertArrayEquals("Raw $name", values, actual.longs.getValue(name))
    }

    private fun digest(values: OutputArrays): String {
        val bytes = ByteBuffer.allocate(values.floats.values.sumOf { it.size * 4 } + values.longs.values.sumOf { it.size * 8 })
        for (array in values.floats.values) for (value in array) bytes.putInt(value.toRawBits())
        for (array in values.longs.values) for (value in array) bytes.putLong(value)
        return sha256(bytes.array())
    }

    companion object {
        private const val SHIPPED_SHA = "72ceec326ca440e476f02114b97880e2137a41b9e862ba7b46a5a5593c1425d2"
        private fun elementCount(shape: LongArray): Int {
            var count = 1L
            for (dimension in shape) {
                require(dimension > 0 && dimension <= Int.MAX_VALUE && count <= Int.MAX_VALUE / dimension)
                count *= dimension
            }
            return count.toInt()
        }
        private fun directBytes(elements: Int, size: Int): ByteBuffer {
            require(elements > 0 && elements <= Int.MAX_VALUE / size)
            return ByteBuffer.allocateDirect(elements * size).order(ByteOrder.nativeOrder())
        }
        private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
