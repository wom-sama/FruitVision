package vn.mangodemo.mango_offline

import android.graphics.Bitmap
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

@RunWith(AndroidJUnit4::class)
class NativePreprocessorDeviceTest {
    @Test fun nativePillowResizePackingMatchesEveryFloatAndMeasuresPairedCost() {
        val inst=InstrumentationRegistry.getInstrumentation()
        val baseline=LiveSamples(60);val native=LiveSamples(60)
        val direct=ByteBuffer.allocateDirect(3*480*480*4).order(ByteOrder.nativeOrder())
        val actual=direct.asFloatBuffer()
        val samples=(0..5).map { i -> inst.context.assets.open("fruit_stage/actual_source_$i.png").use { BitmapFactory.decodeStream(it) } }
        val reusable=ImageResampler.Reusable()
        NativePreprocessor().use { prep ->
            for(round in 0 until 66) {
                val bitmap=samples[round%6];val scale=480.0/maxOf(bitmap.width,bitmap.height)
                val w=maxOf(1,(bitmap.width*scale).toInt());val h=maxOf(1,(bitmap.height*scale).toInt())
                val left=(480-w)/2;val top=(480-h)/2
                val source=IntArray(bitmap.width*bitmap.height)
                val expected=FloatArray(3*480*480) {128/255f}
                for(kind in if(round%2==0) listOf(0,1) else listOf(1,0)) {
                    val began=SystemClock.elapsedRealtimeNanos()
                    if(kind==0) {
                        bitmap.getPixels(source,0,bitmap.width,0,0,bitmap.width,bitmap.height)
                        val pixels=reusable.resizeRgb(source,bitmap.width,bitmap.height,w,h)
                        for(y in 0 until h) for(x in 0 until w) {
                            val p=pixels[y*w+x];val index=(top+y)*480+left+x
                            expected[index]=((p ushr 16) and 255)/255f
                            expected[480*480+index]=((p ushr 8) and 255)/255f
                            expected[2*480*480+index]=(p and 255)/255f
                        }
                    } else assertTrue(prep.prepare(bitmap,direct,480,w,h,left,top))
                    if(round>=6)(if(kind==0) baseline else native).add((SystemClock.elapsedRealtimeNanos()-began)/1e6)
                }
                val observed=FloatArray(expected.size);actual.rewind();actual.get(observed)
                assertArrayEquals("round$round",expected,observed,0f)
            }
            val transparent=Bitmap.createBitmap(10,10,Bitmap.Config.ARGB_8888)
            try { assertFalse(prep.prepare(transparent,direct,480,480,480,0,0)) } finally { transparent.recycle() }
        }
        samples.forEach {it.recycle()}
        val closed=NativePreprocessor();closed.close();closed.close()
        val bitmap=Bitmap.createBitmap(10,10,Bitmap.Config.ARGB_8888)
        try { assertThrows(IllegalStateException::class.java) {closed.prepare(bitmap,direct,480,480,480,0,0)} } finally {bitmap.recycle()}
        val report=mapOf("samples" to 60,"images" to 6,"all_floats_exact" to true,
            "kotlin_p50_ms" to baseline.percentile(.5),"native_p50_ms" to native.percentile(.5),
            "kotlin_p95_ms" to baseline.percentile(.95),"native_p95_ms" to native.percentile(.95))
        File(inst.targetContext.filesDir,"native_preprocessing_paired.json").writeText(JSONObject(report).toString(2))
        assertTrue("Native preprocessing must demonstrate improvement: $report",native.percentile(.5)<baseline.percentile(.5)*.8)
    }
}
