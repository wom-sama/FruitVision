package vn.mangodemo.mango_offline

/** A live overlay can identify a detected species without inventing its grade. */
internal data class LiveObjectPresentation(val classId: Int?, val label: String) {
    companion object {
        fun fromResult(index: Int, result: Map<*, *>, trackId: Int? = index + 1): LiveObjectPresentation {
            require(index in 0..63)
            require(trackId == null || trackId in 1..10000)
            val prefix = trackId?.let { "#$it · " } ?: ""
            val direct=result["gradeScheme"]=="source_two_stage"
            val species = result["species"] as? String
            val unsupported = result["status"] == "UNSUPPORTED_SPECIES"
            val name = if (direct) null else when (species) {
                "banana" -> "Chuối"
                "apple" -> "Táo"
                "orange" -> "Cam"
                "mango" -> if (unsupported || direct) "Xoài" else null
                null -> null
                else -> species
            }
            val classId = result["classId"] as? Int
            if (unsupported) require(!species.isNullOrBlank() && !result.containsKey("classId") &&
                !result.containsKey("probabilities")) { "Invalid ungraded live object" }
            else require(result["status"] in setOf("OK", "UNCERTAIN") && classId != null && classId in 0..(if(direct) 1 else 4)) {
                "Invalid graded live object"
            }
            if (result["status"] == "UNCERTAIN") return LiveObjectPresentation(null,
                "$prefix${if (name == null) "" else "$name · "}Chưa rõ")
            return LiveObjectPresentation(classId,
                "$prefix${if (name == null) "" else "$name · "}${if (unsupported) "Chưa hỗ trợ" else if(direct) (if(classId==0) "Xanh" else "Chín") else "Lớp $classId"}")
        }
    }
}
