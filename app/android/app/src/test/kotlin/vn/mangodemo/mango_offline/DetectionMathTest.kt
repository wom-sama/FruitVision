package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class DetectionMathTest {
    @Test fun denseSceneRetainsSixtyFourDisjointFruitAndReportsTruncation() {
        val coordinates = FloatArray(65*4)
        repeat(65) { index ->
            val left=(index%9)*50f; val top=(index/9)*50f
            coordinates[index*4]=left; coordinates[index*4+1]=top
            coordinates[index*4+2]=left+20f; coordinates[index*4+3]=top+20f
        }
        val result=DetectionMath.select(coordinates,FloatArray(65) { .9f },
            InferenceMath.letterbox(480,480,480),.35,.5,64)
        assertEquals(64,result.boxes.size)
        assertEquals(64,result.boxes.map { it.box.toList() }.distinct().size)
        assertTrue(result.limitReached)
        val exactly=DetectionMath.select(coordinates.copyOf(64*4),FloatArray(64) { .9f },
            InferenceMath.letterbox(480,480,480),.35,.5,64)
        assertEquals(64,exactly.boxes.size); assertFalse(exactly.limitReached)
    }
    @Test fun oversizedDenseLimitIsRejectedInsteadOfAllocatingUnboundedOutput() {
        assertThrows(IllegalArgumentException::class.java) {
            DetectionMath.select(floatArrayOf(0f,0f,20f,20f),floatArrayOf(.9f),
                InferenceMath.letterbox(480,480,480),.35,.5,65)
        }
    }
    @Test fun idsUseDeclaredSpeciesOrderIncludingMangoAndIdsBeyondCocoTriplet() {
        val c = DetectorOutputContract.fromMetadata(mapOf("species_names" to
            listOf("papaya", "mango", "apple", "guava", "orange", "banana")))
        val output = DetectionMath.select(
            floatArrayOf(0f,32f,30f,96f, 50f,32f,80f,96f, 100f,32f,130f,96f,
                150f,32f,180f,96f, 200f,32f,230f,96f, 250f,32f,280f,96f),
            floatArrayOf(.95f,.9f,.85f,.8f,.75f,.7f), InferenceMath.letterbox(100,100,320),
            .25,.5,8,longArrayOf(0,1,2,3,4,5), speciesNames = c.speciesNames)
        assertEquals(listOf("papaya", "mango", "apple", "guava", "orange", "banana"), output.boxes.map { it.species })
    }
    @Test fun idsAreBoundedByActualDeclaredNamespaceRatherThanOldTriplet() {
        for (ids in listOf(longArrayOf(1), longArrayOf(-2), longArrayOf(-1), longArrayOf(0,1))) {
            assertThrows(IllegalArgumentException::class.java) {
                DetectionMath.select(floatArrayOf(0f,0f,40f,40f), floatArrayOf(.8f),
                    InferenceMath.letterbox(100,100,320), .25,.5,8, ids, speciesNames = listOf("mango"))
            }
        }
    }
    @Test fun classAgnosticNmsKeepsHighestSpeciesScoreAndDisjointFruit() {
        val output = DetectionMath.select(
            floatArrayOf(32f,32f,128f,128f, 34f,34f,130f,130f, 192f,32f,288f,128f),
            floatArrayOf(.8f,.9f,.7f), InferenceMath.letterbox(100,100,320), .25,.5,8,
            longArrayOf(0,1,0), "class_agnostic", listOf("banana", "apple", "orange"))
        assertEquals(listOf("apple", "banana"), output.boxes.map { it.species })
        assertEquals(.9, output.boxes[0].score, 1e-6)
        assertArrayEquals(doubleArrayOf(.6,.1,.9,.4), output.boxes[1].box, 1e-7)
        assertFalse(output.limitReached)
    }
    @Test fun malformedNmsModeFailsBeforeReturningDetections() {
        assertThrows(IllegalArgumentException::class.java) {
            DetectionMath.select(floatArrayOf(0f,0f,40f,40f), floatArrayOf(.8f),
                InferenceMath.letterbox(100,100,320), .25,.5,8, longArrayOf(0), "unknown")
        }
    }
    @Test fun speciesAwareNmsKeepsDifferentFruitAndDropsNonfruitWinner() {
        val output = DetectionMath.select(floatArrayOf(32f,32f,128f,128f, 32f,32f,128f,128f,
            34f,34f,130f,130f, 180f,180f,250f,250f), floatArrayOf(.9f,.8f,.7f,0f),
            InferenceMath.letterbox(100,100,320), .0,.5,8,longArrayOf(0,1,0,-1),
            speciesNames = listOf("banana", "apple", "orange"))
        assertEquals(listOf("banana","apple"), output.boxes.map { it.species })
        assertEquals(2,output.boxes.size)
    }
    @Test fun invalidSpeciesOrNonfruitWithPositiveScoreFailsClosed() {
        for (ids in listOf(longArrayOf(3),longArrayOf(-2),longArrayOf(-1),longArrayOf(0,1))) {
            assertThrows(IllegalArgumentException::class.java) {
                DetectionMath.select(floatArrayOf(0f,0f,40f,40f),floatArrayOf(.8f),
                    InferenceMath.letterbox(100,100,320),.25,.5,8,ids,
                    speciesNames = listOf("banana", "apple", "orange"))
            }
        }
    }
    @Test fun twoFruitsHaveIndependentBoxesAndDuplicateIsSuppressed() {
        val output = DetectionMath.select(floatArrayOf(32f,32f,128f,128f, 34f,34f,130f,130f, 192f,32f,288f,128f),
            floatArrayOf(.9f,.8f,.7f), InferenceMath.letterbox(100,100,320), .25, .5, 8)
        assertEquals(2, output.boxes.size)
        assertEquals(listOf("mango", "mango"), output.boxes.map { it.species })
        assertArrayEquals(doubleArrayOf(.1,.1,.4,.4), output.boxes[0].box, 1e-7)
        assertArrayEquals(doubleArrayOf(.6,.1,.9,.4), output.boxes[1].box, 1e-7)
        assertFalse(output.limitReached)
    }
    @Test fun paddingOnlyDetectionIsDiscardedRatherThanInventingAFruit() {
        val output = DetectionMath.select(floatArrayOf(40f,0f,100f,60f, 32f,112f,128f,208f),
            floatArrayOf(.99f,.8f), InferenceMath.letterbox(100,50,320), .25,.5,8)
        assertEquals(1, output.boxes.size)
        assertArrayEquals(doubleArrayOf(.1,.2,.4,.8), output.boxes[0].box, 1e-7)
    }
    @Test fun reachingCropBudgetIsExplicitAndRetainsHighestScores() {
        val coordinates = floatArrayOf(0f,0f,40f,40f, 80f,0f,120f,40f, 160f,0f,200f,40f)
        val output = DetectionMath.select(coordinates, floatArrayOf(.6f,.9f,.8f), InferenceMath.letterbox(100,100,320), .25,.5,2)
        assertEquals(2, output.boxes.size); assertTrue(output.limitReached)
        assertEquals(.9, output.boxes[0].score, 1e-6)
        assertEquals(.8, output.boxes[1].score, 1e-6)
    }
    @Test fun cropContextUsesEachFruitAndClampsAtImageBorders() {
        assertArrayEquals(intArrayOf(16,50,64,170), DetectionMath.crop(doubleArrayOf(.2,.3,.6,.8),100,200,.1))
        assertArrayEquals(intArrayOf(0,0,100,200), DetectionMath.crop(doubleArrayOf(0.0,0.0,1.0,1.0),100,200,.1))
    }
    @Test(expected=IllegalArgumentException::class) fun corruptScoresFailClosed() {
        DetectionMath.select(floatArrayOf(0f,0f,10f,10f),floatArrayOf(Float.NaN),InferenceMath.letterbox(100,100,320),.25,.5,8)
    }
    @Test(expected=IllegalArgumentException::class) fun reversedCropIsNotClassified() {
        DetectionMath.crop(doubleArrayOf(.6,.3,.2,.8),100,200,.1)
    }
}
