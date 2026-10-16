package vn.mangodemo.mango_offline

/** Main-thread gate: identity comes from the existing Dart counter, never another tracker. */
internal class LiveOverlayIdentity {
    private var timestampMs: Long? = null
    private var count = 0
    fun frame(timestampMs: Long, count: Int) {
        require(timestampMs >= 0 && count in 0..32)
        this.timestampMs = timestampMs; this.count = count
    }
    fun clear() { timestampMs = null; count = 0 }
    fun accepts(timestampMs: Long, ids: List<Int>): Boolean {
        if (this.timestampMs != timestampMs) return false
        require(ids.size == count && ids.all { it in 1..10000 } && ids.distinct().size == ids.size)
        return true
    }
}
