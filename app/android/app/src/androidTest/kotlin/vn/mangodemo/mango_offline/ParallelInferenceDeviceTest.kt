package vn.mangodemo.mango_offline

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.FloatBuffer
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentLinkedQueue

/** Measurement only: two independent sessions, not an enabled app runtime policy. */
@RunWith(AndroidJUnit4::class)
class ParallelInferenceDeviceTest {
    @Test fun twoCpuSessionsPreserveEveryOutputAndMeasureRunOnlyThroughput() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        NativeInferenceEngine(context).use { it.prepare(true) }
        val path=File(context.filesDir,"models/mango_detector.onnx")
        val environment=OrtEnvironment.getEnvironment()
        fun options()=OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2);setInterOpNumThreads(1)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            addConfigEntry("session.intra_op.allow_spinning","0")
            addConfigEntry("session.inter_op.allow_spinning","0")
        }
        // Separate borrowed buffers/tensors and sessions: no mutable inference state shared.
        val inputs=(0..1).map { worker ->
            val values=FloatArray(3*480*480) { index -> ((index*13+worker*7)%256)/255f }
            OnnxTensor.createTensor(environment,FloatBuffer.wrap(values),longArrayOf(1,3,480,480))
        }
        val sequential=mutableListOf<Double>()
        val parallel=mutableListOf<Double>()
        fun digest(result:OrtSession.Result):String {
            val hash=MessageDigest.getInstance("SHA-256")
            for(name in listOf("boxes","scores","stage_scores")) {
                val values=(result.get(name).get() as OnnxTensor).floatBuffer
                val bytes=ByteBuffer.allocate(values.remaining()*4)
                bytes.asFloatBuffer().put(values)
                hash.update(bytes.array())
            }
            for(name in listOf("species_ids","stage_ids")) {
                val values=(result.get(name).get() as OnnxTensor).longBuffer
                val bytes=ByteBuffer.allocate(values.remaining()*8)
                bytes.asLongBuffer().put(values)
                hash.update(bytes.array())
            }
            return hash.digest().joinToString("") { "%02x".format(it) }
        }
        try {
            options().use { a -> options().use { b ->
                environment.createSession(path.absolutePath,a).use { first ->
                    environment.createSession(path.absolutePath,b).use { second ->
                        val pool=Executors.newFixedThreadPool(2)
                        val ownedResults=ConcurrentLinkedQueue<OrtSession.Result>()
                        try {
                        val sessions=listOf(first,second)
                        val expected=sessions.mapIndexed { i,s -> s.run(mapOf("image" to inputs[i])).use { digest(it) } }
                        fun work(i:Int):OrtSession.Result=sessions[i].run(mapOf("image" to inputs[i])).also { ownedResults.add(it) }
                        repeat(10) { wave ->
                            for(mode in if(wave%2==0) listOf(0,1) else listOf(1,0)) {
                                val began=SystemClock.elapsedRealtimeNanos()
                                val results=if(mode==0) listOf(work(0),work(1)) else {
                                    val futures=(0..1).map { i -> pool.submit(Callable { work(i) }) }
                                    futures.map { it.get(20,TimeUnit.SECONDS) }
                                }
                                val ms=(SystemClock.elapsedRealtimeNanos()-began)/1e6
                                // Verification must not inflate the graph latency being compared.
                                val actual=results.map { digest(it) }
                                results.forEach { it.close();ownedResults.remove(it) }
                                assertEquals("Raw outputs changed under concurrency",expected,actual)
                                if(wave>=2) (if(mode==0) sequential else parallel).add(ms)
                            }
                        }
                        } finally {
                            // Finish owned work before either session or input is closed.
                            pool.shutdownNow()
                            assertTrue("Benchmark worker did not stop",pool.awaitTermination(10,TimeUnit.SECONDS))
                            ownedResults.forEach { it.close() }
                        }
                    }
                }
            } }
        } finally {
            inputs.forEach { it.close() }
        }
        fun median(values:List<Double>)=values.sorted()[values.size/2]
        val single=median(sequential);val dual=median(parallel)
        val report=JSONObject().put("samples",sequential.size).put("jobsPerWave",2)
            .put("sequentialWaveP50Ms",single).put("parallelWaveP50Ms",dual)
            .put("sequentialGraphJobsPerSecond",2000/single).put("parallelGraphJobsPerSecond",2000/dual)
            .put("speedup",single/dual).put("allRawOutputsIdentical",true)
            .put("modelSha256",MessageDigest.getInstance("SHA-256").digest(path.readBytes()).joinToString("") { "%02x".format(it) })
            .put("enabledInApp",false)
            .put("outputVerificationTimed",false)
            .put("limitations","Synthetic fixed tensors; ORT run plus dispatch/join, excludes output digest/camera/decode/preprocessing/tracking/rendering or fruit accuracy. Emulator only.")
        File(context.filesDir,"parallel_cpu_run_only_probe.json").writeText(report.toString(2))
    }
}
