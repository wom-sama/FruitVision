package vn.mangodemo.mango_offline

import kotlin.math.ceil

/** Worker-confined admission: skip early frames; never queue a catch-up burst. */
class LiveFramePolicy(maxFps: Int) {
    private var intervalNs: Long
    private var nextNs = Long.MIN_VALUE
    var delivered = 0L; private set
    var skipped = 0L; private set
    init { require(maxFps in 1..30); intervalNs = 1_000_000_000L / maxFps }
    fun setMaxFps(maxFps: Int) { require(maxFps in 1..30); intervalNs = 1_000_000_000L / maxFps }
    fun accept(nowNs: Long): Boolean {
        delivered++
        if (nowNs < nextNs) { skipped++; return false }
        nextNs = nowNs + intervalNs
        return true
    }
    companion object {
        /** Android thermal status: 2=MODERATE, 3=SEVERE; never exceeds user's cap. */
        fun thermalFps(requested: Int, status: Int): Int = minOf(requested, when {
            status >= 3 -> 1
            status >= 2 -> 3
            else -> requested
        })
    }
}

/** Fixed-size timing window, not an unbounded per-frame log. */
class LiveSamples(private val capacity: Int = 120) {
    private val values = DoubleArray(capacity)
    var count = 0; private set
    private var cursor = 0
    init { require(capacity > 0) }
    fun add(value: Double) {
        require(value.isFinite() && value >= 0)
        values[cursor] = value
        cursor = (cursor + 1) % capacity
        count = minOf(count + 1, capacity)
    }
    fun percentile(fraction: Double): Double {
        require(fraction in 0.0..1.0)
        if (count == 0) return 0.0
        val sorted = values.copyOf(count).apply { sort() }
        return sorted[(ceil(fraction * count).toInt() - 1).coerceIn(0, count - 1)]
    }
}
