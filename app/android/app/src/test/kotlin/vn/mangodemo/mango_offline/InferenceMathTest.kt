package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class InferenceMathTest {
    @Test fun explicitTopLeftFloorsNonIntegralResizeWhileLegacyStillRounds() {
        val topLeft = InferenceMath.letterbox(201, 301, 480, "top_left")
        assertEquals(320, topLeft.scaledWidth); assertEquals(480, topLeft.scaledHeight)
        assertEquals(0, topLeft.left); assertEquals(0, topLeft.top)
        assertEquals(321, InferenceMath.letterbox(201, 301, 480).scaledWidth)
    }
    @Test fun officialCocoTopLeftLetterboxDoesNotSubtractCenteredPadding() {
        val transform=InferenceMath.letterbox(200,100,480,"top_left")
        assertEquals(0,transform.left);assertEquals(0,transform.top)
        assertEquals(480,transform.scaledWidth);assertEquals(240,transform.scaledHeight)
        assertArrayEquals(doubleArrayOf(.1,.2,.8,.8),transform.toOriginal(doubleArrayOf(.1,.1,.8,.4)),1e-8)
        assertThrows(IllegalArgumentException::class.java) { InferenceMath.letterbox(200,100,480,"unknown") }
    }
    @Test fun detectorUsesValidatedExportResolutionInsteadOfHardcoded320() {
        assertEquals(320, InferenceMath.detectorInputSize(longArrayOf(1,3,320,320)))
        assertEquals(480, InferenceMath.detectorInputSize(longArrayOf(1,3,480,480)))
        val transform = InferenceMath.letterbox(200,100,InferenceMath.detectorInputSize(longArrayOf(1,3,480,480)))
        assertEquals(480, transform.scaledWidth); assertEquals(240, transform.scaledHeight)
        assertArrayEquals(doubleArrayOf(.1,.1,.9,.9),
            transform.toOriginal(doubleArrayOf(.1,.3,.9,.7)), 1e-7)
    }
    @Test fun malformedOrUnboundedDetectorInputFailsBeforeAllocation() {
        for (shape in listOf(longArrayOf(1,3,480,320), longArrayOf(2,3,480,480),
                longArrayOf(1,1,480,480), longArrayOf(1,3,-1,-1), longArrayOf(1,3,4096,4096))) {
            try { InferenceMath.detectorInputSize(shape); fail("Invalid detector shape accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun softmaxRemainsFiniteForLargeLogits() {
        val p = InferenceMath.softmax(floatArrayOf(1000f, 1000f, -1000f, -1000f, -1000f), 1.0)
        assertArrayEquals(doubleArrayOf(.5, .5, 0.0, 0.0, 0.0), p, 1e-8)
    }
    @Test fun emptyMaskDoesNotProduceFakeBox() {
        assertNull(InferenceMath.largestBox(FloatArray(16) { -20f }, 4, 4))
    }
    @Test fun componentBelowOnePercentIsNotPromoted() {
        val mask = FloatArray(56 * 56) { -20f }
        for (i in 0 until 31) mask[i] = 20f
        assertNull(InferenceMath.largestBox(mask, 56, 56))
        mask[31] = 20f
        assertNotNull(InferenceMath.largestBox(mask, 56, 56))
    }
    @Test fun largestConnectedComponentRejectsSmallNoise() {
        val mask = FloatArray(36) { -20f }
        for (y in 1..3) for (x in 2..4) mask[y * 6 + x] = 20f
        mask[0] = 20f
        val box = InferenceMath.largestBox(mask, 6, 6)!!
        assertArrayEquals(doubleArrayOf(2.0/6, 1.0/6, 5.0/6, 4.0/6), box, 1e-8)
    }
    @Test fun landscapeMappingRemovesVerticalLetterboxPadding() {
        val t = InferenceMath.letterbox(400, 200, 224)
        assertEquals(224, t.scaledWidth)
        assertEquals(112, t.scaledHeight)
        assertArrayEquals(doubleArrayOf(.25, .0, .75, 1.0), t.toOriginal(doubleArrayOf(.25, .25, .75, .75)), 1e-8)
    }
    @Test fun portraitMappingClampsAtImageEdges() {
        val t = InferenceMath.letterbox(100, 200, 224)
        assertArrayEquals(doubleArrayOf(0.0, 0.0, 1.0, 1.0), t.toOriginal(doubleArrayOf(0.0, 0.0, 1.0, 1.0)), 1e-8)
    }
    @Test(expected = IllegalArgumentException::class)
    fun malformedNanOutputIsRejected() {
        InferenceMath.softmax(floatArrayOf(Float.NaN, 1f, 2f, 3f, 4f), 1.0)
    }
}
