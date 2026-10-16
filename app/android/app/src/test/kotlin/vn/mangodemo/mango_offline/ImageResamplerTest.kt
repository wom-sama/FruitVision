package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class ImageResamplerTest {
    @Test fun reusableResizePreservesPillowPixelsAndDoesNotKeepPreviousFrame() {
        val resize = ImageResampler.Reusable()
        val input = intArrayOf(0xFF000000.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFFFFFFFF.toInt())
        val first = resize.resizeRgb(input, 4, 1, 2, 1)
        assertArrayEquals(intArrayOf(0xFF6D6D6D.toInt(), 0xFF929292.toInt()), first)
        val second = resize.resizeRgb(IntArray(4) { 0xFF123456.toInt() }, 4, 1, 2, 1)
        assertSame(first, second)
        assertArrayEquals(intArrayOf(0xFF123456.toInt(), 0xFF123456.toInt()), second)
        assertArrayEquals(intArrayOf(0xFF808080.toInt()), resize.resizeRgb(
            intArrayOf(0xFF000000.toInt(), 0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt()), 2, 2, 1, 1))
    }
    @Test fun areaDownsamplePreservesCheckerboardAverage() {
        val result = ImageResampler.resizeRgb(intArrayOf(0xFF000000.toInt(), 0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt()), 2, 2, 1, 1)
        assertEquals(0xFF808080.toInt(), result[0])
    }
    @Test fun bilinearDownsampleUsesAntialiasWeightsInsteadOfFourPointSampling() {
        val result = ImageResampler.resizeRgb(intArrayOf(0xFF000000.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 4, 1, 2, 1)
        assertArrayEquals(intArrayOf(0xFF6D6D6D.toInt(), 0xFF929292.toInt()), result)
    }
    @Test fun equalSizeDoesNotChangePixels() {
        val input = intArrayOf(0xFF123456.toInt(), 0xFFABCDEF.toInt())
        assertArrayEquals(input, ImageResampler.resizeRgb(input, 1, 2, 1, 2))
    }
    @Test fun upsampleMatchesPillowBilinearRounding() {
        val input = intArrayOf(0xFF000000.toInt(), 0xFFFFFFFF.toInt())
        assertArrayEquals(intArrayOf(0xFF000000.toInt(), 0xFF191919.toInt(),
            0xFF808080.toInt(), 0xFFE6E6E6.toInt(), 0xFFFFFFFF.toInt()),
            ImageResampler.resizeRgb(input, 2, 1, 5, 1))
    }
}
