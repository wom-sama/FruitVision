package vn.mangodemo.mango_offline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FVFaceFramingGateTest {
    private val centered = FVFaceObservation(.5f, .43f, .2f, .8f, 0f)
    private fun frame(gate: FVFaceFramingGate, at: Long, face: FVFaceObservation = centered) =
        gate.observe(listOf(face), at)

    @Test fun oneGoodSnapshotCannotTriggerCaptureEvenAfterLongWait() {
        val gate = FVFaceFramingGate()
        assertFalse(frame(gate, 100_000).ready)
        assertEquals(0f, frame(FVFaceFramingGate(), 100_000).fraction, 0f)
    }

    @Test fun stableCaptureRequiresBothTimeAndRepeatedObservations() {
        val gate = FVFaceFramingGate()
        assertFalse(frame(gate, 1000).ready)
        assertFalse(frame(gate, 1300).ready)
        assertFalse(frame(gate, 1699).ready)
        val accepted = frame(gate, 1700)
        assertTrue(accepted.ready)
        assertEquals(1f, accepted.fraction, 0f)
        val twoFrames = FVFaceFramingGate()
        frame(twoFrames, 0)
        assertFalse(frame(twoFrames, 900).ready)
        assertTrue(frame(twoFrames, 1200).ready)
    }

    @Test fun disappearanceOrSecondPersonRevokesAnAlmostCompletedHold() {
        for (invalid in listOf(emptyList(), listOf(centered, centered.copy(x = .7f)))) {
            val gate = FVFaceFramingGate()
            frame(gate, 1000)
            frame(gate, 1600)
            val rejected = gate.observe(invalid, 1700)
            assertFalse(rejected.ready)
            assertEquals(0f, rejected.fraction, 0f)
            assertFalse(frame(gate, 1800).ready)
            assertFalse(frame(gate, 2100).ready)
            assertTrue(frame(gate, 2500).ready)
        }
    }

    @Test fun nonfiniteGeometryConfidenceAndPoseNeverCaptureOrPreserveTheHold() {
        val invalid = listOf(
            centered.copy(x = Float.NaN), centered.copy(y = Float.POSITIVE_INFINITY),
            centered.copy(eyeRatio = Float.NaN), centered.copy(confidence = Float.NaN),
            centered.copy(roll = Float.NEGATIVE_INFINITY)
        )
        for (face in invalid) {
            val gate = FVFaceFramingGate()
            frame(gate, 0)
            frame(gate, 400)
            assertFalse(frame(gate, 800, face).ready)
            assertFalse(frame(gate, 900).ready)
        }
    }

    @Test fun lowQualityDistanceOffCenterAndTiltCannotTriggerAnOtherwiseReadyHold() {
        val invalid = listOf(
            centered.copy(confidence = .39f), centered.copy(eyeRatio = .119f),
            centered.copy(eyeRatio = .321f), centered.copy(x = .2f),
            centered.copy(x = .8f), centered.copy(y = .2f), centered.copy(y = .7f),
            centered.copy(roll = 16f), centered.copy(roll = -16f)
        )
        for (face in invalid) {
            val gate = FVFaceFramingGate()
            frame(gate, 100)
            frame(gate, 500)
            assertFalse(frame(gate, 900, face).ready)
            assertFalse(frame(gate, 1000).ready)
            assertFalse(frame(gate, 1300).ready)
            assertTrue(frame(gate, 1700).ready)
        }
    }

    @Test fun suddenPositionOrDistanceChangeStartsANewHold() {
        for (moved in listOf(centered.copy(x = .55f), centered.copy(eyeRatio = .23f))) {
            val gate = FVFaceFramingGate()
            frame(gate, 0)
            frame(gate, 400)
            val restarted = frame(gate, 800, moved)
            assertFalse(restarted.ready)
            assertEquals(0f, restarted.fraction, 0f)
            assertFalse(frame(gate, 1100, moved).ready)
            assertTrue(frame(gate, 1500, moved).ready)
        }
    }

    @Test fun gradualDriftIsMeasuredAgainstTheHoldAnchorRatherThanOnlyTheLastFrame() {
        val gate = FVFaceFramingGate()
        frame(gate, 0)
        assertFalse(frame(gate, 300, centered.copy(x = .52f)).ready)
        assertFalse(frame(gate, 700, centered.copy(x = .54f)).ready)
        // Each individual movement is small; cumulative drift must still restart the timer.
        assertFalse(frame(gate, 1000, centered.copy(x = .54f)).ready)
        assertTrue(frame(gate, 1400, centered.copy(x = .54f)).ready)
    }

    @Test fun stalledFeedAndBackwardsClockMustNotCountThePreviousFrames() {
        for (nextTime in listOf(2001L, 100L)) {
            val gate = FVFaceFramingGate()
            frame(gate, 200)
            frame(gate, 600)
            assertFalse(frame(gate, nextTime).ready)
            assertFalse(frame(gate, nextTime + 300).ready)
            assertTrue(frame(gate, nextTime + 700).ready)
        }
    }

    @Test fun repeatedTimestampsCannotCompleteTheTimeRequirement() {
        val gate = FVFaceFramingGate()
        repeat(100) { assertFalse(frame(gate, 50).ready) }
        assertTrue(frame(gate, 750).ready)
    }

    @Test fun explicitLifecycleResetRequiresANewStableHold() {
        val gate = FVFaceFramingGate()
        frame(gate, 0)
        frame(gate, 400)
        assertTrue(frame(gate, 800).ready)
        gate.reset()
        assertFalse(frame(gate, 900).ready)
        assertFalse(frame(gate, 1200).ready)
        assertTrue(frame(gate, 1600).ready)
    }
}
