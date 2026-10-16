package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class LiveFramePolicyTest {
    @Test fun thirtyFpsAdmissionKeepsLatestWithoutCatchUpAndStillThermalLimits() {
        val policy = LiveFramePolicy(30)
        assertTrue(policy.accept(0))
        assertFalse(policy.accept(33_000_000))
        assertTrue(policy.accept(34_000_000))
        assertTrue(policy.accept(500_000_000))
        assertFalse(policy.accept(501_000_000))
        assertEquals(3, LiveFramePolicy.thermalFps(30, 2))
        assertEquals(1, LiveFramePolicy.thermalFps(30, 3))
        assertThrows(IllegalArgumentException::class.java) { LiveFramePolicy(31) }
    }
    @Test fun rateLimitNeverQueuesOldFrames() {
        val policy = LiveFramePolicy(5)
        assertTrue(policy.accept(0))
        for (ms in 1L..199L) assertFalse(policy.accept(ms * 1_000_000))
        assertTrue(policy.accept(200_000_000))
        assertEquals(201L, policy.delivered)
        assertEquals(199L, policy.skipped)
    }
    @Test fun slowProcessingDoesNotCreateCatchUpBurst() {
        val policy = LiveFramePolicy(5)
        assertTrue(policy.accept(0))
        assertTrue(policy.accept(900_000_000))
        assertFalse(policy.accept(901_000_000))
    }
    @Test fun sampleWindowIsBoundedAndPercentilesAreNearestRank() {
        val stats = LiveSamples(4)
        for (i in 1..10) stats.add(i.toDouble())
        assertEquals(4, stats.count)
        assertEquals(8.0, stats.percentile(.5), 0.0)
        assertEquals(10.0, stats.percentile(.95), 0.0)
    }
    @Test fun rejectsInvalidRatesAndNonFiniteTiming() {
        assertThrows(IllegalArgumentException::class.java) { LiveFramePolicy(0) }
        assertThrows(IllegalArgumentException::class.java) { LiveSamples().add(Double.NaN) }
    }
    @Test fun thermalBudgetReducesRateWithoutRaisingUserLimit() {
        assertEquals(5, LiveFramePolicy.thermalFps(5, 0))
        assertEquals(3, LiveFramePolicy.thermalFps(5, 2))
        assertEquals(1, LiveFramePolicy.thermalFps(5, 3))
        assertEquals(2, LiveFramePolicy.thermalFps(2, 2))
    }
}
