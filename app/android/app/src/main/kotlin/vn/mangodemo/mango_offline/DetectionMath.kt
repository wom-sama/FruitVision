package vn.mangodemo.mango_offline

import kotlin.math.ceil
import kotlin.math.floor

/** Detector-specific geometry; no image-wide class is inherited by a region. */
object DetectionMath {
    data class Box(val box: DoubleArray, val score: Double, val species: String = "mango",
                   val stageId: Int? = null, val stageScores: DoubleArray? = null)
    data class Selection(val boxes: List<Box>, val limitReached: Boolean)

    fun select(raw: FloatArray, scores: FloatArray, transform: InferenceMath.Letterbox,
               confidence: Double, nmsIou: Double, limit: Int, speciesIds: LongArray? = null,
               nmsMode: String = "class_aware", speciesNames: List<String> = listOf("mango"),
               stageIds: LongArray? = null, stageScores: FloatArray? = null): Selection {
        require(raw.size == scores.size * 4 && raw.all { it.isFinite() } && scores.all { it.isFinite() && it in 0f..1f })
        require(confidence in 0.0..1.0 && nmsIou in 0.0..1.0 && limit in 1..64)
        require((stageIds == null) == (stageScores == null)) { "Partial stage outputs" }
        if (stageIds != null) {
            require(speciesIds != null && stageIds.size == scores.size && stageIds.all { it in 0L..1L } &&
                stageScores!!.size == scores.size*2 && stageScores.all { it.isFinite() && it in 0f..1f }) { "Invalid stage outputs" }
            for (i in scores.indices.filter { scores[it]>=confidence }) require(kotlin.math.abs(stageScores!![2*i]+stageScores[2*i+1]-1f)<.001f &&
                stageScores[2*i+stageIds[i].toInt()] >= stageScores[2*i+1-stageIds[i].toInt()]) { "Invalid stage distribution" }
        }
        require(nmsMode in setOf("class_aware", "class_agnostic")) { "Invalid detector NMS mode" }
        require(speciesNames.isNotEmpty() && speciesNames.distinct().size == speciesNames.size &&
            speciesNames.all { it in DetectorOutputContract.allowedSpeciesNames } &&
            (speciesIds != null || speciesNames == listOf("mango"))) { "Invalid detector species namespace" }
        if (speciesIds != null) require(speciesIds.size == scores.size && speciesIds.indices.all {
            speciesIds[it] >= -1L && speciesIds[it] < speciesNames.size.toLong() &&
                (speciesIds[it] != -1L || scores[it] == 0f)
        }) { "Invalid detector species IDs" }
        if ("fruit" in speciesNames) {
            require(stageIds != null) { "Generic fruit requires explicit grade abstention" }
            for (i in scores.indices.filter { scores[it] >= confidence && speciesIds?.get(it) != -1L }) {
                if (speciesNames[speciesIds!![i].toInt()] == "fruit") require(
                    stageScores!![2*i] == .5f && stageScores[2*i+1] == .5f
                ) { "Generic fruit cannot inherit a banana or mango grade" }
            }
        }
        val candidates = scores.indices.filter { scores[it] >= confidence && speciesIds?.get(it) != -1L }
            .sortedByDescending { scores[it] }
            .mapNotNull { index ->
                val box = transform.toOriginal(DoubleArray(4) { raw[index*4+it].toDouble() / transform.target })
                val species = if (speciesIds == null) "mango" else speciesNames[speciesIds[index].toInt()]
                if (box[0] >= box[2] || box[1] >= box[3]) null else Box(box, scores[index].toDouble(), species,
                    stageIds?.get(index)?.toInt(),stageScores?.let { doubleArrayOf(it[index*2].toDouble(),it[index*2+1].toDouble()) })
            }.take(256)
        val selected = mutableListOf<Box>()
        for (candidate in candidates) {
            if (selected.any { (nmsMode == "class_agnostic" || it.species == candidate.species) &&
                iou(it.box, candidate.box) > nmsIou }) continue
            selected.add(candidate)
            if (selected.size > limit) break
        }
        return Selection(selected.take(limit), selected.size > limit)
    }

    fun iou(a: DoubleArray, b: DoubleArray): Double {
        val width = (minOf(a[2], b[2]) - maxOf(a[0], b[0])).coerceAtLeast(0.0)
        val height = (minOf(a[3], b[3]) - maxOf(a[1], b[1])).coerceAtLeast(0.0)
        val intersection = width * height
        return intersection / ((a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - intersection).coerceAtLeast(1e-12)
    }

    fun crop(box: DoubleArray, width: Int, height: Int, context: Double): IntArray {
        require(box.size == 4 && box.all { it.isFinite() && it in 0.0..1.0 } &&
            box[0] < box[2] && box[1] < box[3] && width > 0 && height > 0 && context.isFinite() && context >= 0)
        val x0=box[0]*width; val x1=box[2]*width; val y0=box[1]*height; val y1=box[3]*height
        val dx=(x1-x0)*context; val dy=(y1-y0)*context
        return intArrayOf(floor(x0-dx+1e-9).toInt().coerceAtLeast(0), floor(y0-dy+1e-9).toInt().coerceAtLeast(0),
            ceil(x1+dx-1e-9).toInt().coerceAtMost(width), ceil(y1+dy-1e-9).toInt().coerceAtMost(height))
    }
}
