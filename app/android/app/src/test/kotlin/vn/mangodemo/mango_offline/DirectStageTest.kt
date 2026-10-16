package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class DirectStageTest {
    @Test fun genericFruitWireResultHasNoInventedSourceGrade() {
        val region=DetectionMath.Box(doubleArrayOf(.1,.2,.3,.4),.8,"fruit",0,doubleArrayOf(.5,.5))
        val result=directStageObject(region)
        assertEquals("fruit",result["species"])
        assertEquals("UNSUPPORTED_SPECIES",result["status"])
        assertEquals(false,result["graded"])
        assertFalse(result.containsKey("classId"))
        assertFalse(result.containsKey("probabilities"))
        val summary=directStageSummary(listOf(result))
        assertEquals("UNSUPPORTED_SPECIES",summary["status"])
        assertEquals("fruit",summary["species"])
        assertFalse(summary.containsKey("classId"))
    }
    @Test fun mixedSceneSummaryDoesNotCopyAnUngradedFruitAsAMangoGrade() {
        val generic=directStageObject(DetectionMath.Box(doubleArrayOf(.1,.2,.3,.4),.8,"fruit",0,doubleArrayOf(.5,.5)))
        val mango=directStageObject(DetectionMath.Box(doubleArrayOf(.5,.2,.7,.4),.9,"mango",1,doubleArrayOf(.1,.9)))
        assertEquals("OK",mango["status"])
        assertEquals(1,mango["classId"])
        val summary=directStageSummary(listOf(generic,mango))
        assertEquals("mango",summary["species"])
        assertEquals(1,summary["classId"])
        assertEquals("NO_FRUIT",directStageSummary(emptyList())["status"])
    }
    @Test fun sixtyFourthLiveFruitDoesNotCrashOrAcquireAnUnknownGrade() {
        val objectResult=mapOf<String,Any>("species" to "fruit","status" to "UNSUPPORTED_SPECIES",
            "gradeScheme" to "source_two_stage","graded" to false)
        val displayed=LiveObjectPresentation.fromResult(63,objectResult,64)
        assertNull(displayed.classId)
        assertTrue(displayed.label.startsWith("#64"))
        assertFalse(displayed.label.contains("Chín"))
        assertThrows(IllegalArgumentException::class.java) { LiveObjectPresentation.fromResult(64,objectResult,65) }
    }
    @Test fun genericFruitIsAllowedOnlyWithExplicitDirectGradeAbstention() {
        val metadata=mapOf<String,Any?>("species_names" to listOf("banana","mango","fruit"),
            "stage_labels" to listOf("Xanh / chưa chín","Chín"),
            "geometry_only_grade_abstention" to true)
        assertEquals(listOf("banana","mango","fruit"), DetectorOutputContract.fromMetadata(metadata).speciesNames)
        for (bad in listOf(metadata-"stage_labels",
            metadata-"geometry_only_grade_abstention",
            metadata+mapOf("geometry_only_grade_abstention" to false))) {
            assertThrows(IllegalArgumentException::class.java) { DetectorOutputContract.fromMetadata(bad) }
        }
    }
    @Test fun genericFruitRetainsGeometryButCannotCarryConfidentSourceGrade() {
        fun choose(probabilities:FloatArray) = DetectionMath.select(floatArrayOf(0f,0f,80f,80f),floatArrayOf(.9f),
            InferenceMath.letterbox(100,100,320),.35,.5,64,longArrayOf(2),
            speciesNames=listOf("banana","mango","fruit"),stageIds=longArrayOf(0),stageScores=probabilities)
        val found=choose(floatArrayOf(.5f,.5f)).boxes.single()
        assertEquals("fruit",found.species)
        assertEquals(.9,found.score,1e-6)
        assertThrows(IllegalArgumentException::class.java) { choose(floatArrayOf(.9f,.1f)) }
    }
    @Test fun graphRequiresExplicitTwoStageOutputs() {
        val c=DetectorOutputContract.fromMetadata(mapOf("species_names" to listOf("banana","mango"),
            "stage_labels" to listOf("Xanh / chưa chín","Chín")))
        assertEquals(2,c.stageLabels.size)
        val shapes=mapOf("boxes" to longArrayOf(1,4725,4),"scores" to longArrayOf(1,4725),
            "species_ids" to longArrayOf(1,4725),"stage_ids" to longArrayOf(1,4725),"stage_scores" to longArrayOf(1,4725,2))
        c.validateGraph(shapes,setOf("boxes","scores","stage_scores"),setOf("species_ids","stage_ids"))
        assertThrows(IllegalArgumentException::class.java) {
            c.validateGraph(shapes+mapOf("stage_scores" to longArrayOf(1,4725,5)),
                setOf("boxes","scores","stage_scores"),setOf("species_ids","stage_ids"))
        }
    }
    @Test fun geometrySelectionRetainsStagesWithTheirOwnBoxes() {
        val result=DetectionMath.select(floatArrayOf(0f,0f,80f,80f,160f,160f,240f,240f),floatArrayOf(.8f,.9f),
            InferenceMath.letterbox(100,100,320),.35,.5,32,longArrayOf(0,1),speciesNames=listOf("banana","mango"),
            stageIds=longArrayOf(0,1),stageScores=floatArrayOf(.9f,.1f,.2f,.8f))
        assertEquals(listOf("mango","banana"),result.boxes.map { it.species })
        assertEquals(listOf(1,0),result.boxes.map { it.stageId })
        assertEquals(listOf(.2,.8),result.boxes.first().stageScores!!.map { Math.round(it*10)/10.0 })
    }
    @Test fun impossibleStageCannotBeSilentlyAccepted() {
        assertThrows(IllegalArgumentException::class.java) {
            DetectionMath.select(floatArrayOf(0f,0f,80f,80f),floatArrayOf(.9f),InferenceMath.letterbox(100,100,320),
                .35,.5,32,longArrayOf(0),speciesNames=listOf("banana"),stageIds=longArrayOf(4),stageScores=floatArrayOf(.1f,.9f))
        }
    }
    @Test fun directStageOverlayNamesActualSourceStage() {
        val p=LiveObjectPresentation.fromResult(12,mapOf("species" to "mango","status" to "OK",
            "classId" to 1,"gradeScheme" to "source_two_stage"))
        assertTrue(p.label.contains("Chín"));assertFalse(p.label.contains("Xoài"))
        val banana=LiveObjectPresentation.fromResult(12,mapOf("species" to "banana","status" to "OK",
            "classId" to 1,"gradeScheme" to "source_two_stage"))
        assertEquals(p.label,banana.label)
    }
}
