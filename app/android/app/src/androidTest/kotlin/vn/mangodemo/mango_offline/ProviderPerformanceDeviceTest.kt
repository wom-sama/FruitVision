package vn.mangodemo.mango_offline

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.BitmapFactory
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.FloatBuffer
import kotlin.math.abs

/** Tests the identical graph on two real runtime providers, not a new trained model. */
@RunWith(AndroidJUnit4::class)
class ProviderPerformanceDeviceTest {
    @Test fun compareCpuAndXnnpackOnSameImagesAndAllRawOutputs() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        NativeInferenceEngine(context).use { it.prepare(true) }
        val env = OrtEnvironment.getEnvironment()
        val path = File(context.filesDir, "models/mango_detector.onnx").absolutePath
        fun options(xnn: Boolean) = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(if (xnn) 1 else 2); setInterOpNumThreads(1)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            addConfigEntry("session.intra_op.allow_spinning", "0")
            addConfigEntry("session.inter_op.allow_spinning", "0")
            if (xnn) addXnnpack(mapOf("intra_op_num_threads" to "2"))
        }
        val inputs = (0..5).map { index ->
            val bitmap = assets.open("fruit_stage/actual_source_$index.png").use { BitmapFactory.decodeStream(it) }
            val source = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(source, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            val scale = 480.0 / maxOf(bitmap.width, bitmap.height)
            val w = maxOf(1, (bitmap.width * scale).toInt()); val h = maxOf(1, (bitmap.height * scale).toInt())
            val resized = ImageResampler.resizeRgb(source, bitmap.width, bitmap.height, w, h)
            bitmap.recycle()
            val pixels = IntArray(480*480) { 0xff808080.toInt() }
            for (row in 0 until h) resized.copyInto(pixels, (row+(480-h)/2)*480+(480-w)/2, row*w, (row+1)*w)
            val tensor = FloatArray(3*pixels.size)
            for (channel in 0..2) for (i in pixels.indices) tensor[channel*pixels.size+i] = ((pixels[i] ushr (16-channel*8)) and 255)/255f
            OnnxTensor.createTensor(env, FloatBuffer.wrap(tensor), longArrayOf(1,3,480,480))
        }
        val cpu = LiveSamples(30); val xnn = LiveSamples(30)
        val errors = mutableMapOf("boxes" to 0.0, "scores" to 0.0, "stage_scores" to 0.0)
        var idDifferences = 0
        try {
            options(false).use { a -> options(true).use { b ->
                env.createSession(path,a).use { first -> env.createSession(path,b).use { second ->
                    for (round in 0 until 36) {
                        val input = mapOf("image" to inputs[round%6])
                        var firstOutput: OrtSession.Result? = null; var secondOutput: OrtSession.Result? = null
                        try {
                            for (kind in if(round%2==0) listOf(0,1) else listOf(1,0)) {
                                val began = SystemClock.elapsedRealtimeNanos()
                                if(kind==0) firstOutput=first.run(input) else secondOutput=second.run(input)
                                if(round>=6) (if(kind==0) cpu else xnn).add((SystemClock.elapsedRealtimeNanos()-began)/1e6)
                            }
                            for (name in errors.keys.toList()) {
                                val left=(firstOutput!!.get(name).get() as OnnxTensor).floatBuffer
                                val right=(secondOutput!!.get(name).get() as OnnxTensor).floatBuffer
                                assertEquals(left.remaining(),right.remaining())
                                while(left.hasRemaining()) errors[name]=maxOf(errors.getValue(name), abs(left.get().toDouble()-right.get().toDouble()))
                            }
                            for (name in listOf("species_ids","stage_ids")) {
                                val left=(firstOutput!!.get(name).get() as OnnxTensor).longBuffer
                                val right=(secondOutput!!.get(name).get() as OnnxTensor).longBuffer
                                while(left.hasRemaining()) if(left.get()!=right.get()) idDifferences++
                            }
                        } finally { firstOutput?.close(); secondOutput?.close() }
                    }
                } }
            } }
        } finally { inputs.forEach { it.close() } }
        val report = mapOf("samples" to 30,"warmups" to 6,"device" to android.os.Build.MODEL,
            "cpu_p50_ms" to cpu.percentile(.5),"cpu_p95_ms" to cpu.percentile(.95),
            "xnnpack_p50_ms" to xnn.percentile(.5),"xnnpack_p95_ms" to xnn.percentile(.95),
            "max_raw_errors" to errors,"raw_id_differences" to idDifferences)
        File(context.filesDir,"provider_paired.json").writeText(JSONObject(report).toString(2))
        assertTrue(errors.getValue("boxes")<=.002 && errors.getValue("scores")<=1e-4 && errors.getValue("stage_scores")<=1e-4)
        assertEquals(0,idDifferences)
    }
}
