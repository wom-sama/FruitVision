package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class NativeVideoFrameMathTest {
    @Test fun uprightCoordinatesFollowClockwiseRotationWithoutMirroring() {
        val expected = mapOf(
            0 to listOf(1,2,3,4,5,6,7,8),
            90 to listOf(5,1,6,2,7,3,8,4),
            180 to listOf(8,7,6,5,4,3,2,1),
            270 to listOf(4,8,3,7,2,6,1,5))
        for ((rotation, pixels) in expected) {
            val geometry = NativeVideoPixels.geometry(4, 2, rotation, 1600)
            val actual = (0 until geometry.height).flatMap { y ->
                (0 until geometry.width).map { x ->
                    1 + geometry.sourceIndex(x, y)
                }
            }
            assertEquals("rotation=$rotation", pixels, actual)
        }
    }

    @Test fun boundedGeometryKeepsAspectAndSamplesInsideSource() {
        val geometry = NativeVideoPixels.geometry(640, 480, 90, 320)
        assertEquals(240, geometry.width)
        assertEquals(320, geometry.height)
        assertEquals(305921, geometry.sourceIndex(0,0))
        assertEquals(639, geometry.sourceIndex(239,319))
        assertThrows(IllegalArgumentException::class.java) { NativeVideoPixels.geometry(0,2,0,1600) }
        assertThrows(IllegalArgumentException::class.java) { NativeVideoPixels.geometry(2,2,45,1600) }
    }

    @Test fun paddedInterleavedPlanesRespectPositionRowStrideAndPixelStride() {
        val buffer = ByteBuffer.wrap(byteArrayOf(99,10,77,20,77,66,66,30,77,40))
        buffer.position(1)
        assertEquals(10, NativeVideoPixels.sample(buffer,6,2,0,0))
        assertEquals(20, NativeVideoPixels.sample(buffer,6,2,1,0))
        assertEquals(30, NativeVideoPixels.sample(buffer,6,2,0,1))
        assertEquals(40, NativeVideoPixels.sample(buffer,6,2,1,1))
        assertEquals(1, buffer.position())
        assertThrows(IllegalArgumentException::class.java) { NativeVideoPixels.sample(buffer,6,2,2,1) }
    }

    @Test fun limitedAndFullVideoRangesDoNotTurnBlackGrayOrWhiteDark() {
        assertEquals(0xFF000000.toInt(), NativeVideoPixels.argb(16,128,128,false,false))
        assertEquals(0xFFFFFFFF.toInt(), NativeVideoPixels.argb(235,128,128,false,false))
        assertEquals(0xFFFF0000.toInt(), NativeVideoPixels.argb(81,90,240,false,false))
        assertEquals(0xFF000000.toInt(), NativeVideoPixels.argb(0,128,128,true,false))
        assertEquals(0xFFFFFFFF.toInt(), NativeVideoPixels.argb(255,128,128,true,true))
    }
}
