package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
class DirectStageDeviceTest {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val fixtures get()=InstrumentationRegistry.getInstrumentation().context.assets
    private fun fixture(name:String):File=File(context.cacheDir,name).also { file ->
        fixtures.open("fruit_stage/$name").use { input -> file.outputStream().use { input.copyTo(it) } }
    }
    private fun assertDirectStageObject(obj:Map<*,*>) {
        assertEquals("source_two_stage",obj["gradeScheme"])
        assertTrue(obj["species"] in listOf("mango","banana","fruit"))
        if(obj["species"]=="fruit") {
            assertEquals(false,obj["graded"])
            assertEquals("UNSUPPORTED_SPECIES",obj["status"])
            assertFalse(obj.containsKey("classId"))
            assertFalse(obj.containsKey("probabilities"))
        } else {
            assertEquals(true,obj["graded"])
            val probabilities=obj["probabilities"] as List<*>
            assertEquals(2,probabilities.size)
            val values=probabilities.map { (it as Number).toDouble() }
            assertTrue(values.all { it.isFinite() && it in 0.0..1.0 })
            assertEquals(1.0,values.sum(),1e-6)
            val classId=obj["classId"] as Int
            assertEquals(if(values[1]>values[0]) 1 else 0,classId)
            assertEquals(if(values[classId]>=.6) "OK" else "UNCERTAIN",obj["status"])
        }
    }
    @Test fun actualSixPhotosMatchIndependentDesktopAndRunOneEncoderOffline() {
        val expected=fixtures.open("fruit_stage/expected.json").bufferedReader().use { JSONObject(it.readText()) }
        val records=mutableListOf<Map<String,Any>>()
        NativeInferenceEngine(context).use { engine ->
            val prepared=engine.prepare(true)
            assertEquals("detection_stages",prepared["graderMode"])
            assertEquals(listOf("Xanh / chưa chín","Chín"),prepared["classLabels"])
            assertEquals(expected.getString("model_sha256"),prepared["modelSha256"])
            val items=expected.getJSONArray("records")
            for(i in 0 until items.length()) {
                val item=items.getJSONObject(i); val name=item.getString("file")
                val actual=engine.analyzeImage(fixture(name).absolutePath,true)
                assertTrue(actual["runtimeProvider"] in setOf("CPU", "CPU (3 threads)", "CPU (4 threads)", "NNAPI + CPU", "XNNPACK + CPU"))
                assertNotEquals("pending", actual["runtimeSelection"])
                val objects=actual["objects"] as List<*>
                val wanted=item.getJSONArray("objects")
                assertEquals("Object count $name",wanted.length(),objects.size)
                var maxBoxError=0.0;var maxScoreError=0.0
                objects.forEachIndexed { j,value ->
                    val obj=value as Map<*,*>;val truth=wanted.getJSONObject(j)
                    assertDirectStageObject(obj)
                    assertEquals(truth.getString("species"),obj["species"])
                    assertEquals(truth.getBoolean("graded"),obj["graded"])
                    assertEquals(truth.getString("status"),obj["status"])
                    val box=obj["box"] as List<*>
                    for(k in 0..3) maxBoxError=maxOf(maxBoxError,kotlin.math.abs((box[k] as Double)-truth.getJSONArray("box").getDouble(k)))
                    if(truth.getBoolean("graded")) {
                        assertEquals(truth.getInt("classId"),obj["classId"])
                        val p=obj["probabilities"] as List<*>
                        for(k in 0..1) maxScoreError=maxOf(maxScoreError,kotlin.math.abs((p[k] as Double)-truth.getJSONArray("probabilities").getDouble(k)))
                    } else {
                        assertFalse(truth.has("classId"))
                        assertFalse(truth.has("probabilities"))
                    }
                }
                assertTrue("Box error $name $maxBoxError",maxBoxError<.005)
                assertTrue("Score error $name $maxScoreError",maxScoreError<.01)
                records.add(mapOf("file" to name,"count" to objects.size,"maxBoxError" to maxBoxError,
                    "maxStageScoreError" to maxScoreError,"elapsedMs" to actual["elapsedMs"]!!,"modelMs" to actual["modelMs"]!!,
                    "nativePssMb" to actual["nativePssMb"]!!,"runtimeProvider" to actual["runtimeProvider"]!!,
                    "runtimeSelection" to actual["runtimeSelection"]!!,"runtimeTuningMs" to actual["runtimeTuningMs"]!!))
            }
        }
        File(context.filesDir,"direct_stage_photo_verification.json").writeText(JSONObject(mapOf("records" to records)).toString(2))
    }
    @Test fun realVideoUsesAndroidDecoderAndReturnsPerFruitStagesWithoutQueue() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare(true)
            val path=fixture("real_video_excerpt.mp4").absolutePath
            val info=engine.videoInfo(path);assertTrue((info["durationMs"] as Long)>1000)
            val records=mutableListOf<Map<String,Any>>()
            for(timestamp in listOf(0L,500L,1000L)) {
                val result=engine.analyzeVideoFrame(path,timestamp,true)
                assertEquals(timestamp,result["timestampMs"])
                val objects=result["objects"] as List<*>
                assertTrue(objects.size<=64)
                for(value in objects) {
                    assertDirectStageObject(value as Map<*,*>)
                }
                assertTrue(File(result["previewPath"] as String).isFile)
                records.add(mapOf("timestampMs" to timestamp,"objects" to objects,"elapsedMs" to result["elapsedMs"]!!))
            }
            File(context.filesDir,"direct_stage_video_verification.json").writeText(JSONObject(mapOf("records" to records,
                "input" to "real user video excerpt; no manual count/stage GT" )).toString(2))
        }
    }
    @Test fun flatNonfruitAndCameraHotPathAreSafeAndDoNotWritePreviewFiles() {
        NativeInferenceEngine(context).use { engine ->
            engine.prepare(true)
            val bitmap=Bitmap.createBitmap(640,480,Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.rgb(128,128,128))
                val before=context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() }
                val result=engine.analyzeCameraBitmap(bitmap,SystemClock.elapsedRealtimeNanos(),true)
                assertEquals("NO_FRUIT",result["status"])
                assertTrue((result["objects"] as List<*>).isEmpty())
                assertFalse(result.containsKey("previewPath"))
                assertEquals(before,context.cacheDir.listFiles()!!.filter { it.name.startsWith("preview_") }.associate { it.name to it.lastModified() })
            } finally { bitmap.recycle() }
        }
    }
}
