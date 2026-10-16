package vn.mangodemo.mango_offline

import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer

@RunWith(AndroidJUnit4::class)
class NativeYuvConverterDeviceTest {
    private fun plane(bytes: Int, rowStride: Int, pixelStride: Int, position: Int, value: Int): NativeYuvConverter.Plane {
        val buffer=ByteBuffer.allocateDirect(bytes)
        for(i in 0 until bytes) buffer.put(i,value.toByte())
        buffer.position(position)
        return NativeYuvConverter.Plane(buffer,rowStride,pixelStride)
    }

    @Test fun oddCropAndAllRotationsRespectPlanePositionsAndPixelStrides() {
        val y=plane(64,16,2,3,0);val u=plane(20,8,2,1,128);val v=plane(20,8,2,1,128)
        for(row in 0..2) for(col in 0..4) y.buffer.put(3+row*16+col*2,(row*10+col+1).toByte())
        val expectations=mapOf(0 to listOf(12,13,14,22,23,24),90 to listOf(22,12,23,13,24,14),
            180 to listOf(24,23,22,14,13,12),270 to listOf(14,24,13,23,12,22))
        for((rotation,wanted) in expectations) {
            val bitmap=NativeYuvConverter.convert(y,u,v,1,1,3,2,rotation,1600,true,false)
            try {
                val pixels=IntArray(6);bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
                assertEquals(wanted,pixels.map { Color.red(it) })
                assertTrue(pixels.all { Color.red(it)==Color.green(it) && Color.red(it)==Color.blue(it) })
                assertEquals(3,y.buffer.position());assertEquals(1,u.buffer.position())
            } finally { bitmap.recycle() }
        }
    }

    @Test fun fullAndLimitedBt601AndBt709UseExactRgbCoefficients() {
        val y=plane(4,2,1,0,100);val u=plane(1,1,1,0,180);val v=plane(1,1,1,0,128)
        val wanted=mapOf((true to false) to Color.rgb(100,82,192),(true to true) to Color.rgb(100,90,196),
            (false to false) to Color.rgb(98,77,203),(false to true) to Color.rgb(98,87,208))
        for((flags,color) in wanted) {
            val bitmap=NativeYuvConverter.convert(y,u,v,0,0,2,2,0,1600,flags.first,flags.second)
            try { assertEquals(color,bitmap.getPixel(1,1)) } finally { bitmap.recycle() }
        }
    }

    @Test fun downsampleUsesPixelCentersWithoutChangingFrameOrientation() {
        val y=plane(16,4,1,0,0);val u=plane(4,2,1,0,128);val v=plane(4,2,1,0,128)
        for(row in 0..3) for(col in 0..3) y.buffer.put(row*4+col,(row*10+col+1).toByte())
        val bitmap=NativeYuvConverter.convert(y,u,v,0,0,4,4,0,2,true,false)
        try {
            val pixels=IntArray(4);bitmap.getPixels(pixels,0,2,0,0,2,2)
            assertEquals(listOf(12,14,32,34),pixels.map { Color.red(it) })
        } finally { bitmap.recycle() }
    }

    @Test fun truncatedDirectPlaneIsRejectedBeforeOutOfBoundsNativeReads() {
        val y=plane(16,4,1,0,100);val u=plane(4,2,1,0,128);val v=plane(4,2,1,0,128)
        y.buffer.limit(15)
        assertThrows(IllegalArgumentException::class.java) {
            NativeYuvConverter.convert(y,u,v,0,0,4,4,0,1600,true,false)
        }
    }
}
