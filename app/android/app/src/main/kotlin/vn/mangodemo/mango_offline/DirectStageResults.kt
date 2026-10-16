package vn.mangodemo.mango_offline

/** Unknown fruit contributes a region/count, never an inherited mango/banana grade. */
internal fun directStageObject(region: DetectionMath.Box): Map<String,Any> {
    val base=mapOf<String,Any>("box" to region.box.toList(),"detectionScore" to region.score,
        "species" to region.species,"gradeScheme" to "source_two_stage")
    if (region.species == "fruit") return base+mapOf("graded" to false,"status" to "UNSUPPORTED_SPECIES")
    val label=requireNotNull(region.stageId)
    val scores=requireNotNull(region.stageScores)
    return base+mapOf("classId" to label,"probabilities" to scores.toList(),"graded" to true,
        "status" to if(scores[label]>=.6) "OK" else "UNCERTAIN")
}

/** Legacy scalar fields are compatibility only; the scene consumes per-object grades. */
internal fun directStageSummary(objects: List<Map<String,Any>>): Map<String,Any> {
    if(objects.isEmpty()) return mapOf("status" to "NO_FRUIT")
    val representative=objects.firstOrNull { it["graded"] == true }
        ?: return mapOf("status" to "UNSUPPORTED_SPECIES","species" to "fruit")
    return listOf("classId","probabilities","status","species").associateWith { requireNotNull(representative[it]) }
}
