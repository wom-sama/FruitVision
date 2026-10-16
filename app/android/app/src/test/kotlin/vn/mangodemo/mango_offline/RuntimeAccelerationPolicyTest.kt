package vn.mangodemo.mango_offline
import org.junit.Assert.*
import org.junit.Test

class RuntimeAccelerationPolicyTest {
    @Test fun workerThreadsAreBoundedByCoresAndLowMemoryUse() {
        assertEquals(1, RuntimeAccelerationPolicy.workerThreads(8, true))
        assertEquals(1, RuntimeAccelerationPolicy.workerThreads(1, false))
        assertEquals(2, RuntimeAccelerationPolicy.workerThreads(2, false))
        assertEquals(2, RuntimeAccelerationPolicy.workerThreads(4, false))
        assertEquals(2, RuntimeAccelerationPolicy.workerThreads(8, false))
        assertEquals(2, RuntimeAccelerationPolicy.workerThreads(32, false))
    }
    @Test fun candidatePlanUsesAvailableCoresAndHardwareApiWithoutPhoneAllowlist() {
        assertEquals(listOf("XNNPACK"), RuntimeAccelerationPolicy.candidates(2, 26))
        assertEquals(listOf("CPU4", "NNAPI", "XNNPACK"), RuntimeAccelerationPolicy.candidates(8, 36))
        assertEquals(listOf("NNAPI", "XNNPACK"), RuntimeAccelerationPolicy.candidates(2, 29))
        assertEquals(listOf("CPU4", "XNNPACK"), RuntimeAccelerationPolicy.candidates(4, 28))
    }
    @Test fun fasterButNumericallyDifferentProviderMustNotBeSelected() {
        assertFalse(RuntimeAccelerationPolicy.useCandidate(listOf(50.0,51.0,52.0), listOf(10.0,11.0,12.0), false))
    }
    @Test fun selectsOnlyConsistentMeasuredImprovement() {
        assertTrue(RuntimeAccelerationPolicy.useCandidate(listOf(50.0,51.0,52.0), listOf(30.0,31.0,32.0), true))
        assertFalse(RuntimeAccelerationPolicy.useCandidate(listOf(50.0,51.0,52.0), listOf(49.0,50.0,51.0), true))
        assertFalse(RuntimeAccelerationPolicy.useCandidate(listOf(50.0,51.0,52.0), listOf(20.0,21.0,100.0), true))
    }
    @Test fun invalidMeasurementsCannotEnableAnAccelerator() {
        assertFalse(RuntimeAccelerationPolicy.useCandidate(listOf(50.0,51.0,52.0), listOf(Double.NaN,1.0,2.0), true))
        assertFalse(RuntimeAccelerationPolicy.useCandidate(emptyList(), emptyList(), true))
    }
}
