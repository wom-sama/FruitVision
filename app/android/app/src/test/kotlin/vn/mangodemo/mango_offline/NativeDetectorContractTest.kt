package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class NativeDetectorContractTest {
    private fun contract(metadata:Map<String,Any?>) = DetectorOutputContract.fromMetadata(metadata)
    @Test fun directDenseObjectBudgetAcceptsSixtyFourAndRejectsInvalidCounts() {
        val direct=mapOf<String,Any?>("species_names" to listOf("mango"),
            "stage_labels" to listOf("Xanh / chưa chín","Chín"))
        contract(direct+mapOf("max_classified_objects" to 64))
        for (limit in listOf<Any?>(0,65,64.5,"64",null)) {
            assertThrows("Invalid limit=$limit",IllegalArgumentException::class.java) {
                contract(direct+mapOf("max_classified_objects" to limit))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            contract(mapOf("max_classified_objects" to 9))
        }
    }
    @Test fun declaredSpeciesNamespacePreservesMangoAndReorderedNames() {
        val names = listOf("papaya", "mango", "apple", "guava", "orange", "banana")
        val c = contract(mapOf("species_names" to names))
        assertTrue(c.speciesAware)
        assertEquals(listOf("papaya", "mango", "apple", "guava", "orange", "banana"), c.speciesNames)
        c.validateGraph(mapOf("boxes" to longArrayOf(1,6,4), "scores" to longArrayOf(1,6),
            "species_ids" to longArrayOf(1,6)), setOf("boxes", "scores"), setOf("species_ids"))
    }
    @Test fun malformedEmptyDuplicateOrUnknownSpeciesNamespacesFailClosed() {
        for (names in listOf<Any?>(null, "mango", emptyList<String>(), listOf("mango", "mango"),
            listOf("mango", "pear"), listOf("Mango"), listOf(" mango"), listOf("mango", 1))) {
            assertThrows(IllegalArgumentException::class.java) { contract(mapOf("species_names" to names)) }
        }
    }
    @Test fun nmsModeIsExplicitAndMissingMetadataPreservesClassAwareDefault() {
        assertEquals("class_aware", contract(emptyMap()).nmsMode)
        assertEquals("class_aware", contract(mapOf("nms_mode" to "class_aware")).nmsMode)
        assertEquals("class_agnostic", contract(mapOf("nms_mode" to "class_agnostic")).nmsMode)
    }
    @Test fun malformedDeclaredNmsModeFailsClosed() {
        for (mode in listOf<Any?>(null, false, 1, "", "CLASS_AGNOSTIC", "unknown")) {
            assertThrows(IllegalArgumentException::class.java) { contract(mapOf("nms_mode" to mode)) }
        }
    }
    @Test fun canonicalSpeciesGraphUsesTopLeft114AndExactTypedIds() {
        val c=contract(mapOf("species_names" to listOf("banana","apple","orange"),
            "letterbox_alignment" to "top_left","padding_rgb" to listOf(114,114,114)))
        c.validateGraph(mapOf("boxes" to longArrayOf(1,4725,4),"scores" to longArrayOf(1,4725),
            "species_ids" to longArrayOf(1,4725)),setOf("boxes","scores"),setOf("species_ids"))
        assertEquals("top_left",c.alignment);assertArrayEquals(intArrayOf(114,114,114),c.paddingRgb)
        assertTrue(c.speciesAware)
        assertThrows(IllegalArgumentException::class.java) { c.validateGraph(mapOf("boxes" to longArrayOf(1,4725,4),
            "scores" to longArrayOf(1,4725),"species_ids" to longArrayOf(1,4724)),setOf("boxes","scores"),setOf("species_ids")) }
        assertThrows(IllegalArgumentException::class.java) { c.validateGraph(mapOf("boxes" to longArrayOf(1,4725,4),
            "scores" to longArrayOf(1,4725),"species_ids" to longArrayOf(1,4725)),setOf("boxes","scores","species_ids"),emptySet()) }
    }
    @Test fun legacyMetadataPreservesCentered128AndTwoOutputGraph() {
        val c=contract(emptyMap());assertEquals("center",c.alignment)
        assertArrayEquals(intArrayOf(128,128,128),c.paddingRgb);assertFalse(c.speciesAware)
        assertEquals(listOf("mango"), c.speciesNames)
        c.validateGraph(mapOf("boxes" to longArrayOf(1,3234,4),"scores" to longArrayOf(1,3234)),setOf("boxes","scores"),emptySet())
    }
    @Test fun partialPreprocessingFailsClosed() {
        for (m in listOf(mapOf("species_names" to listOf("banana","apple","orange"),"letterbox_alignment" to "top_left"),
            mapOf("letterbox_alignment" to "invalid"),mapOf("padding_rgb" to listOf(256,128,128)))) {
            assertThrows(IllegalArgumentException::class.java) { contract(m) }
        }
    }
}
