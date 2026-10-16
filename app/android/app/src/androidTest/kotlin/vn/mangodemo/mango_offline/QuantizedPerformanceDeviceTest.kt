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
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Paired same-AVD workload; graph timing is deliberately separate from camera FPS. */
@RunWith(AndroidJUnit4::class)
class QuantizedPerformanceDeviceTest {
    @Test fun quantizedGraphImprovesPairedLatencyAtOriginalResolution() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val fixtures=instrumentation.context.assets
        val environment=OrtEnvironment.getEnvironment()
        val baseline=File(context.cacheDir,"perf_baseline_fp32.onnx")
        fixtures.open("fruit_stage/baseline_fp32.onnx").use { source -> baseline.outputStream().use { source.copyTo(it) } }
        val candidate=File(context.filesDir,"models/mango_detector.onnx")
        NativeInferenceEngine(context).use { it.prepare(true) }
        fun options()=OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2);setInterOpNumThreads(1)
            setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            addConfigEntry("session.intra_op.allow_spinning","0")
            addConfigEntry("session.inter_op.allow_spinning","0")
        }
        val inputs=(0..2).map { index ->
            val bitmap=fixtures.open("fruit_stage/actual_source_$index.png").use { BitmapFactory.decodeStream(it) }
            val scale=480.0/maxOf(bitmap.width,bitmap.height)
            val width=maxOf(1,(bitmap.width*scale).toInt());val height=maxOf(1,(bitmap.height*scale).toInt())
            val left=(480-width)/2;val top=(480-height)/2
            val pixels=IntArray(bitmap.width*bitmap.height)
            bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
            val resized=ImageResampler.resizeRgb(pixels,bitmap.width,bitmap.height,width,height)
            bitmap.recycle()
            val canvas=IntArray(480*480) { 0xff808080.toInt() }
            for(row in 0 until height) resized.copyInto(canvas,(top+row)*480+left,row*width,(row+1)*width)
            val buffer=ByteBuffer.allocateDirect(3*480*480*4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            for(channel in 0..2) for(pixel in canvas)buffer.put(((pixel shr (16-channel*8)) and 255)/255f)
            buffer.flip()
            OnnxTensor.createTensor(environment,buffer,longArrayOf(1,3,480,480))
        }
        val fp=LiveSamples(30);val quant=LiveSamples(30)
        try {
            options().use { a -> options().use { b ->
                environment.createSession(baseline.absolutePath,a).use { first ->
                    environment.createSession(candidate.absolutePath,b).use { second ->
                        for(round in 0 until 35) {
                            val input=mapOf("image" to inputs[round%3])
                            val ordered=if(round%2==0) listOf(first to fp,second to quant) else listOf(second to quant,first to fp)
                            for((session,stats) in ordered) {
                                val began=SystemClock.elapsedRealtimeNanos()
                                session.run(input).use { result -> assertEquals(5,result.size()) }
                                if(round>=5)stats.add((SystemClock.elapsedRealtimeNanos()-began)/1e6)
                            }
                        }
                    }
                }
            } }
            val report=mapOf("device" to android.os.Build.MODEL,"samples_per_model" to 30,
                "workload" to "3 real photos480;5warmups;interleaved FP32/INT8;CPU2threads;graph only",
                "fp32_p50_ms" to fp.percentile(.5),"fp32_p95_ms" to fp.percentile(.95),
                "int8_p50_ms" to quant.percentile(.5),"int8_p95_ms" to quant.percentile(.95),
                "speedup_p50" to fp.percentile(.5)/quant.percentile(.5))
            File(context.filesDir,"quantized_paired_performance.json").writeText(JSONObject(report).toString(2))
            assertTrue("INT8 not faster on this Android workload: $report",quant.percentile(.5)<fp.percentile(.5)*.9)
        } finally { inputs.forEach { it.close() } }
    }
}
