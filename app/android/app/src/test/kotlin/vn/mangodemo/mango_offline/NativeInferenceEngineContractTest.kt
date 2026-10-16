package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

/** Real contract/scene result behavior, without constructing Android or ORT sessions. */
class NativeInferenceEngineContractTest {
    private fun speciesMetadata(): Map<String,Any?> = mapOf(
        "output_names" to listOf("logits","mask_logits","species_logits"),
        "output_shapes" to listOf(listOf(1,5),listOf(1,1,56,56),listOf(1,7)),
        "species_head" to mapOf("output_name" to "species_logits", "mango_index" to 0,
            "threshold" to .5,"other_species_threshold" to .5,
            "class_labels" to listOf("mango","apple","guava","papaya","banana","orange","other_or_background")))
    @Test fun sevenSpeciesSceneUsesTheRealSharedHeadAndKeepsMangoGradeFour() {
        val c=contract(speciesMetadata())
        validate(c,shapes(false)+("species_logits" to longArrayOf(1,7)))
        assertEquals(setOf("logits","species_logits"),c.sceneOutputNames)
        val mango=scene(c,grading()+mapOf("speciesLogits" to listOf(10.0,0.0,0.0,0.0,0.0,0.0,0.0)))!!
        assertEquals("mango",mango["species"]);assertEquals(4,mango["classId"])
    }
    @Test fun confidentOtherSpeciesAreUngradedAndUncertainOrBackgroundIsDropped() {
        val c=contract(speciesMetadata())
        for ((index,name) in listOf("apple","guava","papaya","banana","orange").withIndex()) {
            val values=MutableList(7){0.0}.also { it[index+1]=10.0 }
            val item=scene(c,grading()+mapOf("speciesLogits" to values))!!
            assertEquals(name,item["species"]);assertEquals("UNSUPPORTED_SPECIES",item["status"])
            assertFalse(item.containsKey("classId"));assertFalse(item.containsKey("probabilities"))
        }
        assertNull(scene(c,grading()+mapOf("speciesLogits" to listOf(0.0,.1,0.0,0.0,0.0,0.0,0.0))))
        assertNull(scene(c,grading()+mapOf("speciesLogits" to listOf(0.0,0.0,0.0,0.0,0.0,0.0,10.0))))
        assertEquals("NO_FRUIT",c.sceneSummary(emptyList())["status"])
        assertFalse(c.sceneSummary(emptyList()).containsKey("classId"))
    }
    @Test fun malformedSpeciesGraphOrMetadataCannotFallbackToTheLegacyGrader() {
        assertThrows(IllegalArgumentException::class.java) { validate(contract(speciesMetadata()),shapes()) }
        assertThrows(IllegalArgumentException::class.java) { contract(speciesMetadata()+("presence_head" to emptyMap<String,Any>())) }
        for (invalid in listOf<Any?>(null, true,Double.NaN,-.1,1.1)) {
            val head=(speciesMetadata().getValue("species_head") as Map<*,*>).entries.associate { it.key as String to it.value }.toMutableMap()
            head["other_species_threshold"]=invalid
            assertThrows(IllegalArgumentException::class.java) { contract(speciesMetadata()+("species_head" to head)) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            scene(contract(speciesMetadata()),grading()+mapOf("speciesLogits" to listOf(Double.NaN,1.0,0.0,0.0,0.0,0.0,0.0)))
        }
    }
    private fun classifierMetadata():Map<String,Any?> = mapOf("grader_mode" to "classification_only",
        "supported_species" to listOf("banana"),"output_names" to listOf("logits"),"output_shapes" to listOf(listOf(1,5)))
    @Test fun classificationOnlyGraphRequiresRealFiveLogitsAndNoMask() {
        val contract=contract(classifierMetadata())
        validate(contract,mapOf("logits" to longArrayOf(1,5)))
        assertEquals(setOf("logits"),outputNames(contract));assertFalse(contract.hasMask)
        assertThrows(IllegalArgumentException::class.java) { validate(contract,shapes(false)) }
        assertThrows(IllegalArgumentException::class.java) { contract(classifierMetadata()+mapOf("supported_species" to listOf("apple"))) }
        assertThrows(IllegalArgumentException::class.java) { contract(classifierMetadata()+mapOf("presence_head" to emptyMap<String,Any>())) }
    }
    @Test fun unsupportedSpeciesNeverInvokesGraderOrFabricatesGrade() {
        val contract=contract(classifierMetadata());var calls=0
        for (species in listOf("apple","orange","mango")) {
            val row=contract.routeSceneObject(doubleArrayOf(.1,.2,.7,.8),.8,species) { calls++;grading() }!!
            assertEquals(species,row["species"]);assertEquals("UNSUPPORTED_SPECIES",row["status"])
            assertFalse(row.containsKey("classId"));assertFalse(row.containsKey("probabilities"))
        }
        assertEquals(0,calls)
        val banana=contract.routeSceneObject(doubleArrayOf(.1,.2,.7,.8),.8,"banana") { calls++;grading() }!!
        assertEquals(1,calls);assertEquals(4,banana["classId"]);assertEquals("OK",banana["status"])
        assertEquals("banana",banana["species"])
    }
    @Test fun classifierLowConfidenceIsUncertainNotNoFruit() {
        val result=contract(classifierMetadata()).routeSceneObject(doubleArrayOf(.1,.2,.7,.8),.8,"banana") {
            mapOf("classId" to 2,"probabilities" to listOf(.15,.15,.4,.15,.15),"status" to "NO_MANGO")
        }!!
        assertEquals("UNCERTAIN",result["status"]);assertEquals(2,result["classId"])
    }
    @Test fun classifierOnlySceneSummaryNeverInventsScalarGradeForUnsupportedOrEmptyScene() {
        val contract = contract(classifierMetadata())
        val apple = contract.routeSceneObject(doubleArrayOf(.1,.2,.7,.8), .8, "apple") { fail("Unsupported crop graded"); grading() }!!
        val unsupported = contract.sceneSummary(listOf(apple))
        assertEquals("UNSUPPORTED_SPECIES", unsupported["status"])
        assertFalse(unsupported.containsKey("classId")); assertFalse(unsupported.containsKey("probabilities"))
        val empty = contract.sceneSummary(emptyList())
        assertEquals("NO_FRUIT", empty["status"])
        assertFalse(empty.containsKey("classId")); assertFalse(empty.containsKey("probabilities"))
        val banana = contract.routeSceneObject(doubleArrayOf(.1,.2,.7,.8), .8, "banana") { grading() }!!
        val mixed = contract.sceneSummary(listOf(apple, banana))
        assertEquals("OK", mixed["status"]); assertEquals(4, mixed["classId"])
    }
    @Test fun legacyEmptySceneRetainsItsScalarWireCompatibility() {
        val summary = contract(metadata(presence=false)).sceneSummary(emptyList())
        assertEquals("NO_MANGO", summary["status"]); assertEquals(0, summary["classId"])
        assertEquals(List(5) { 0.0 }, summary["probabilities"])
    }
    @Test fun legacyMangoGraderNeverGradesOtherDeclaredFruit() {
        for (species in listOf("apple", "guava", "papaya", "banana", "orange")) {
            val row = contract(metadata(presence=false)).routeSceneObject(doubleArrayOf(.1,.2,.7,.8), .8, species) {
                fail("Legacy mango grader invoked for $species"); grading()
            }!!
            assertEquals("UNSUPPORTED_SPECIES", row["status"])
            assertFalse(row.containsKey("classId")); assertFalse(row.containsKey("probabilities"))
        }
    }
    @Test fun reorderedDetectorObjectsInvokeOriginalMaskGraderForMangoOnly() {
        val names = listOf("apple", "mango", "guava", "papaya", "banana", "orange")
        val c = DetectorOutputContract.fromMetadata(mapOf("species_names" to names))
        val found = DetectionMath.select(
            floatArrayOf(0f,32f,30f,96f, 50f,32f,80f,96f, 100f,32f,130f,96f,
                150f,32f,180f,96f, 200f,32f,230f,96f, 250f,32f,280f,96f),
            floatArrayOf(.95f,.9f,.85f,.8f,.75f,.7f), InferenceMath.letterbox(100,100,320),
            .25,.5,8,longArrayOf(0,1,2,3,4,5), speciesNames = c.speciesNames)
        val grader = contract(metadata(presence=false))
        val invoked = mutableListOf<String>()
        val objects = found.boxes.map { region ->
            grader.routeSceneObject(region.box, region.score, region.species) {
                invoked.add(region.species); grading()
            }!!
        }
        assertEquals(listOf("mango"), invoked)
        assertEquals(listOf("UNSUPPORTED_SPECIES", "OK", "UNSUPPORTED_SPECIES", "UNSUPPORTED_SPECIES",
            "UNSUPPORTED_SPECIES", "UNSUPPORTED_SPECIES"), objects.map { it["status"] })
        assertEquals("mango", objects[1]["species"]); assertEquals(4, objects[1]["classId"])
        for (row in objects.filter { it["species"] != "mango" }) {
            assertFalse(row.containsKey("classId")); assertFalse(row.containsKey("probabilities"))
        }
    }
    private fun metadata(threshold: Any? = .5, presence: Boolean = true): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>(
            "output_names" to listOf("logits", "mask_logits") + if (presence) listOf("mango_logits") else emptyList(),
            "output_shapes" to listOf(listOf(1,5), listOf(1,1,56,56)) + if (presence) listOf(listOf(1,2)) else emptyList())
        if (presence) result["presence_head"] = mapOf("threshold" to threshold,
            "class_labels" to listOf("not_mango", "mango"), "output_name" to "mango_logits")
        return result
    }

    private fun contract(metadata: Map<String, Any?>) = GraderOutputContract.fromMetadata(metadata)
    private fun outputNames(contract: GraderOutputContract) = contract.sceneOutputNames
    private fun validate(contract: GraderOutputContract, shapes: Map<String, LongArray>, floats: Set<String> = shapes.keys) =
        contract.validateGraph(shapes, floats)
    private fun probability(contract: GraderOutputContract, logits: FloatArray) = contract.mangoProbability(logits)
    private fun scene(contract: GraderOutputContract, grading: Map<String, Any>) =
        contract.sceneObject(doubleArrayOf(.1,.2,.7,.8), .7, grading)

    private fun shapes(presence: Boolean = true): Map<String, LongArray> = mutableMapOf(
        "logits" to longArrayOf(1,5), "mask_logits" to longArrayOf(1,1,56,56)).also {
            if (presence) it["mango_logits"] = longArrayOf(1,2)
        }
    private fun grading(mangoProbability: Double? = null): Map<String, Any> = mutableMapOf<String, Any>(
        "classId" to 4, "probabilities" to listOf(.025,.025,.025,.025,.9),
        "status" to "NO_MANGO").also { if (mangoProbability != null) it["mangoProbability"] = mangoProbability }

    @Test fun legacySceneKeepsSpoiledGradeEvenWhenOldMaskStatusSaysNoMango() {
        val contract = contract(metadata(presence=false))
        validate(contract, shapes(false))
        assertEquals(setOf("logits", "mask_logits"), outputNames(contract))
        val result = scene(contract, grading())!!
        assertEquals(4, result["classId"])
        assertEquals("OK", result["status"])
        assertEquals(.7, result["detectionScore"])
        assertFalse(result.containsKey("mangoProbability"))
    }

    @Test fun enabledSceneSelectsGradeAndPresenceTogetherWithoutOldMask() {
        val contract = contract(metadata())
        validate(contract, shapes())
        assertEquals(setOf("logits", "mango_logits"), outputNames(contract))
        val result = scene(contract, grading(.6))!!
        assertEquals(4, result["classId"])
        assertEquals("OK", result["status"])
        assertEquals(.6, result["mangoProbability"])
        assertEquals(listOf(.025,.025,.025,.025,.9), result["probabilities"])
    }

    @Test fun binaryProbabilityIsNotTheFiveGradeConfidenceOrDetectorScore() {
        val result = scene(contract(metadata()), mapOf("classId" to 4,
            "probabilities" to listOf(.15,.15,.15,.15,.4), "mangoProbability" to .99))!!
        assertEquals("UNCERTAIN", result["status"])
        assertEquals(.99, result["mangoProbability"])
        assertEquals(.7, result["detectionScore"])
    }

    @Test fun binaryThresholdEqualityIsKeptButLowerProbabilityIsRejected() {
        val contract = contract(metadata(.5))
        assertNotNull(scene(contract, grading(.5)))
        assertNull(scene(contract, grading(.499999999)))
        assertNotNull(scene(contract, grading(.500000001)))
    }

    @Test fun metadataThresholdIsExplicitNotAHardcodedLearnedOperatingPoint() {
        assertNotNull(scene(contract(metadata(.0)), grading(.0)))
        assertNull(scene(contract(metadata(1.0)), grading(.99)))
        assertNotNull(scene(contract(metadata(1.0)), grading(1.0)))
    }

    @Test fun binarySoftmaxHasTwoLabelsAndStaysFiniteForLargeLogits() {
        val contract = contract(metadata())
        assertEquals(.5, probability(contract, floatArrayOf(1000f,1000f)), 0.0)
        assertEquals(1.0, probability(contract, floatArrayOf(-1000f,1000f)), 0.0)
        assertEquals(.7310585786300049, probability(contract, floatArrayOf(0f,1f)), 1e-12)
    }

    @Test fun invalidThresholdCannotQuietlyDisablePresenceFiltering() {
        for (value in listOf<Any?>(null, true, "0.5", -.01, 1.01, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { contract(metadata(value)) }
        }
    }

    @Test fun nullOrMalformedDeclaredPresenceHeadIsNotLegacyMode() {
        for (value in listOf<Any?>(null, "enabled", emptyMap<String,Any>())) {
            assertThrows(IllegalArgumentException::class.java) { contract(metadata() + ("presence_head" to value)) }
        }
    }

    @Test fun swappedPresenceLabelsOrWrongOutputNameAreRejected() {
        for (head in listOf(
                mapOf("threshold" to .5, "class_labels" to listOf("mango","not_mango"), "output_name" to "mango_logits"),
                mapOf("threshold" to .5, "class_labels" to listOf("not_mango","mango"), "output_name" to "logits"))) {
            assertThrows(IllegalArgumentException::class.java) { contract(metadata() + ("presence_head" to head)) }
        }
    }

    @Test fun metadataOutputShapeOrNamesMustDeclareTheSameThreeHeads() {
        assertThrows(IllegalArgumentException::class.java) {
            contract(metadata() + ("output_shapes" to listOf(listOf(1,5),listOf(1,1,56,56),listOf(1,3))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            contract(metadata() + ("output_names" to listOf("logits","mask_logits")))
        }
        assertThrows(IllegalArgumentException::class.java) {
            contract(metadata(presence=false) + ("output_names" to listOf("logits","mask_logits","mango_logits")))
        }
    }

    @Test fun graphMissingPresenceHeadCannotMatchEnabledMetadata() {
        assertThrows(IllegalArgumentException::class.java) { validate(contract(metadata()), shapes(false)) }
    }

    @Test fun graphPresenceOutputCannotBeImplicitlyEnabledWithoutMetadata() {
        assertThrows(IllegalArgumentException::class.java) { validate(contract(metadata(presence=false)), shapes()) }
    }

    @Test fun graphShapesAndFloatOutputTypesFailClosed() {
        val contract = contract(metadata())
        assertThrows(IllegalArgumentException::class.java) { validate(contract, shapes() + ("mango_logits" to longArrayOf(2,1))) }
        assertThrows(IllegalArgumentException::class.java) { validate(contract, shapes(), setOf("logits","mask_logits")) }
        assertThrows(IllegalArgumentException::class.java) { validate(contract, shapes() + ("other" to longArrayOf(1,2))) }
    }

    @Test fun malformedOrNonfiniteBinaryLogitsCannotProduceAnAcceptedObject() {
        val contract = contract(metadata())
        for (logits in listOf(floatArrayOf(0f), floatArrayOf(0f,0f,0f),
                floatArrayOf(Float.NaN,1f),floatArrayOf(0f,Float.POSITIVE_INFINITY))) {
            assertThrows(IllegalArgumentException::class.java) { probability(contract, logits) }
        }
        assertThrows(IllegalArgumentException::class.java) { scene(contract, grading()) }
        for (value in listOf(Double.NaN,Double.POSITIVE_INFINITY,-.1,1.1)) {
            assertThrows(IllegalArgumentException::class.java) { scene(contract, grading(value)) }
        }
    }
}
