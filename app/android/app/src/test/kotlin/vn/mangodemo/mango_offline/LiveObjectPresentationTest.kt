package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class LiveObjectPresentationTest {
    @Test fun uncertainStageMustNotLookLikeAConfirmedRipeFruit() {
        val item = LiveObjectPresentation.fromResult(0, mapOf("gradeScheme" to "source_two_stage",
            "species" to "mango", "classId" to 1, "status" to "UNCERTAIN"))
        assertNull(item.classId)
        assertEquals("#1 · Chưa rõ", item.label)
    }
    @Test fun unsupportedLiveObjectHasSpeciesLabelAndNoGradeCast() {
        val item = LiveObjectPresentation.fromResult(0, mapOf("species" to "apple", "status" to "UNSUPPORTED_SPECIES"))
        assertNull(item.classId)
        assertEquals("#1 · Táo · Chưa hỗ trợ", item.label)
        val mango = LiveObjectPresentation.fromResult(0, mapOf("species" to "mango", "status" to "UNSUPPORTED_SPECIES"))
        assertEquals("#1 · Xoài · Chưa hỗ trợ", mango.label)
    }
    @Test fun legacyLiveObjectRetainsGradeAndBananaAddsSpecies() {
        val legacy = LiveObjectPresentation.fromResult(1, mapOf("classId" to 4, "status" to "OK"))
        assertEquals(4, legacy.classId); assertEquals("#2 · Lớp 4", legacy.label)
        val banana = LiveObjectPresentation.fromResult(0, mapOf("species" to "banana", "classId" to 2, "status" to "UNCERTAIN"))
        assertNull(banana.classId); assertEquals("#1 · Chuối · Chưa rõ", banana.label)
    }
    @Test fun unsupportedLiveObjectCannotCarryGradeAndOtherStatusesRequireGrade() {
        assertThrows(IllegalArgumentException::class.java) {
            LiveObjectPresentation.fromResult(0, mapOf("species" to "apple", "status" to "UNSUPPORTED_SPECIES", "classId" to 2))
        }
        assertThrows(IllegalArgumentException::class.java) {
            LiveObjectPresentation.fromResult(0, mapOf("status" to "OK"))
        }
    }
}
