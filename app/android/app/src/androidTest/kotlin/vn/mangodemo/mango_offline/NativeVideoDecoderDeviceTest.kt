package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.InterruptedIOException
import java.nio.ByteBuffer

@RunWith(AndroidJUnit4::class)
class NativeVideoDecoderDeviceTest {
    private fun fixture(): File {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        return File(instrumentation.targetContext.cacheDir, "sequential_codec_fixture.mp4").also { file ->
            instrumentation.context.assets.open("codec_fixture.mp4").use { source ->
                file.outputStream().use { source.copyTo(it) }
            }
        }
    }

    @Test fun sequentialDecoderReturnsAllEightActualFramesAndThenStableEos() {
        NativeVideoDecoder(fixture().absolutePath).use { decoder ->
            val timestamps = mutableListOf<Long>()
            while (true) {
                val frame = decoder.nextFrame() ?: break
                frame.use {
                    assertEquals(timestamps.size, it.index)
                    assertEquals(640, it.bitmap.width)
                    assertEquals(852, it.bitmap.height)
                    timestamps.add(it.timestampUs)
                }
            }
            // Independently inspected 4 fps, 8 frame MP4; repeated seeks can miss or duplicate these.
            assertEquals(listOf(0L,250000L,500000L,750000L,1000000L,1250000L,1500000L,1750000L), timestamps)
            assertNull(decoder.nextFrame())
            assertEquals(8, decoder.framesDecoded)
        }
    }

    @Test fun closingMidSequenceAllowsReopenWithoutKeepingCodecFrames() {
        val path = fixture().absolutePath
        val decoder = NativeVideoDecoder(path)
        decoder.nextFrame()!!.close()
        decoder.close()
        decoder.close()
        assertThrows(IllegalStateException::class.java) { decoder.nextFrame() }
        NativeVideoDecoder(path).use { reopened ->
            reopened.nextFrame()!!.use { assertEquals(0L, it.timestampUs) }
        }
    }

    @Test fun sequentialDecoderBorrowsOnePixelBufferUntilDecoderClose() {
        val decoder = NativeVideoDecoder(fixture().absolutePath)
        var storage: Bitmap? = null
        val timestamps = mutableListOf<Long>()
        try {
            repeat(8) { index ->
                val frame = requireNotNull(decoder.nextFrame())
                if (storage == null) storage = frame.bitmap
                else assertSame("Each sequential frame must reuse decoder-owned pixel storage", storage, frame.bitmap)
                assertEquals(index, frame.index)
                assertEquals(640, frame.bitmap.width)
                assertEquals(852, frame.bitmap.height)
                timestamps.add(frame.timestampUs)
                frame.close()
                assertFalse("Closing a borrowed frame must not recycle decoder-owned storage", frame.bitmap.isRecycled)
            }
            assertEquals(listOf(0L,250000L,500000L,750000L,1000000L,1250000L,1500000L,1750000L), timestamps)
            assertNull(decoder.nextFrame())
            assertNull(decoder.nextFrame())
            assertFalse("EOS must not invalidate the last borrowed frame", requireNotNull(storage).isRecycled)
            decoder.close()
            assertTrue("Decoder close must release its retained pixel storage", requireNotNull(storage).isRecycled)
            decoder.close()
        } finally { decoder.close() }
    }

    @Test fun standaloneDecodedFrameStillOwnsAndRecyclesItsBitmap() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val frame = DecodedVideoFrame(bitmap, 0L, 0)
        frame.close()
        frame.close()
        assertTrue(bitmap.isRecycled)
    }

    @Test fun interruptedDecoderReleasesItsBorrowedPixels() {
        val decoder = NativeVideoDecoder(fixture().absolutePath)
        try {
            val frame = requireNotNull(decoder.nextFrame())
            val bitmap = frame.bitmap
            frame.close()
            Thread.currentThread().interrupt()
            assertThrows(InterruptedIOException::class.java) { decoder.nextFrame() }
            assertTrue("Decode failure must release retained storage", bitmap.isRecycled)
            assertThrows(IllegalStateException::class.java) { decoder.nextFrame() }
        } finally {
            Thread.interrupted()
            decoder.close()
        }
    }

    @Test fun converterReusesOnlyExactMutableArgbTargetsAndRetainsCallerOwnershipOnFailure() {
        fun plane(size: Int, row: Int, value: Int): NativeYuvConverter.Plane {
            val bytes = ByteBuffer.allocateDirect(size)
            repeat(size) { bytes.put(it,value.toByte()) }
            return NativeYuvConverter.Plane(bytes,row,1)
        }
        val y=plane(4,2,100);val u=plane(1,1,128);val v=plane(1,1,128)
        val target=Bitmap.createBitmap(2,2,Bitmap.Config.ARGB_8888)
        try {
            val result=NativeYuvConverter.convert(y,u,v,0,0,2,2,0,1600,true,false,target)
            assertSame(target,result)
            assertEquals(Color.rgb(100,100,100),target.getPixel(1,1))
            val invalid = listOf(
                Bitmap.createBitmap(3,2,Bitmap.Config.ARGB_8888),
                Bitmap.createBitmap(2,2,Bitmap.Config.RGB_565),
                requireNotNull(target.copy(Bitmap.Config.ARGB_8888,false)))
            for (bitmap in invalid) {
                try {
                    assertThrows(IllegalArgumentException::class.java) {
                        NativeYuvConverter.convert(y,u,v,0,0,2,2,0,1600,true,false,bitmap)
                    }
                    assertFalse("Rejected caller-owned target must not be recycled",bitmap.isRecycled)
                } finally { bitmap.recycle() }
            }
            y.buffer.limit(3)
            assertThrows(IllegalArgumentException::class.java) {
                NativeYuvConverter.convert(y,u,v,0,0,2,2,0,1600,true,false,target)
            }
            assertFalse("Conversion failure must not recycle caller-owned storage",target.isRecycled)
        } finally { target.recycle() }
    }

    @Test fun decodedSkinColorsAgreeWithAndroidReferenceDecoder() {
        val path=fixture().absolutePath
        val reference=MediaMetadataRetriever()
        reference.setDataSource(path)
        try {
            NativeVideoDecoder(path).use { decoder ->
                repeat(8) {
                    decoder.nextFrame()!!.use { frame ->
                        val wanted=reference.getFrameAtTime(frame.timestampUs,MediaMetadataRetriever.OPTION_CLOSEST)!!
                        try {
                            assertEquals(wanted.width,frame.bitmap.width)
                            assertEquals(wanted.height,frame.bitmap.height)
                            var error=0L; var channels=0
                            for(y in 8 until wanted.height step 32) for(x in 8 until wanted.width step 32) {
                                val a=wanted.getPixel(x,y); val b=frame.bitmap.getPixel(x,y)
                                error+=kotlin.math.abs(Color.red(a)-Color.red(b))+
                                    kotlin.math.abs(Color.green(a)-Color.green(b))+
                                    kotlin.math.abs(Color.blue(a)-Color.blue(b))
                                channels+=3
                            }
                            assertTrue("Mean RGB conversion error=${error.toDouble()/channels}",error.toDouble()/channels<=5.0)
                        } finally { wanted.recycle() }
                    }
                }
            }
        } finally { reference.release() }
    }

    @Test fun inferenceSequenceUsesRealTimestampsAndRetainsRequiredPreviewFields() {
        val path = fixture().absolutePath
        NativeInferenceEngine(InstrumentationRegistry.getInstrumentation().targetContext).use { engine ->
            val info = engine.openVideoSequence(path)
            assertEquals("sequential", info["mode"])
            val first = engine.nextVideoFrame(path, true)
            assertEquals(0L, first["timestampMs"])
            assertEquals(0, first["frameIndex"])
            assertEquals(false, first["endOfStream"])
            assertEquals(true, first["previewUpdated"])
            assertTrue(File(first["previewPath"] as String).isFile)
            assertTrue(first["nativePssMb"] is Number)
            engine.closeVideoSequence()
            engine.closeVideoSequence()
            assertThrows(IllegalStateException::class.java) { engine.nextVideoFrame(path, true) }
            engine.openVideoSequence(path)
            assertEquals(0L, engine.nextVideoFrame(path, true)["timestampMs"])
        }
    }
}
