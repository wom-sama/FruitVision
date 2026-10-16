package vn.mangodemo.mango_offline

import kotlin.math.exp
import kotlin.math.floor

object InferenceMath {
    fun detectorInputSize(shape: LongArray): Int {
        require(shape.size == 4 && shape[0] == 1L && shape[1] == 3L && shape[2] == shape[3] &&
            shape[2] in 224L..640L && shape[2] % 32L == 0L) { "Unsupported detector input" }
        return shape[2].toInt()
    }
    data class Letterbox(val scaledWidth: Int, val scaledHeight: Int, val left: Int, val top: Int, val target: Int) {
        fun toOriginal(box: DoubleArray): DoubleArray {
            require(box.size == 4 && box.all { it.isFinite() })
            return doubleArrayOf(
                ((box[0] * target - left) / scaledWidth).coerceIn(0.0, 1.0),
                ((box[1] * target - top) / scaledHeight).coerceIn(0.0, 1.0),
                ((box[2] * target - left) / scaledWidth).coerceIn(0.0, 1.0),
                ((box[3] * target - top) / scaledHeight).coerceIn(0.0, 1.0))
        }
    }
    fun letterbox(width: Int, height: Int, target: Int, alignment: String = "center"): Letterbox {
        require(width > 0 && height > 0 && target > 0 && alignment in setOf("center", "top_left"))
        val ratio = minOf(target.toDouble() / width, target.toDouble() / height)
        val rounding = if (alignment == "center") .5 else 0.0
        val w = maxOf(1, floor(width * ratio + rounding).toInt())
        val h = maxOf(1, floor(height * ratio + rounding).toInt())
        return Letterbox(w, h, if (alignment == "center") (target - w) / 2 else 0,
            if (alignment == "center") (target - h) / 2 else 0, target)
    }
    fun softmax(logits: FloatArray, temperature: Double): DoubleArray {
        require(logits.size == 5 && logits.all { it.isFinite() }) { "Invalid class logits" }
        require(temperature.isFinite() && temperature > 0)
        val max = logits.max().toDouble()
        val p = DoubleArray(logits.size) { exp((logits[it] - max) / temperature) }
        val sum = p.sum()
        return DoubleArray(p.size) { p[it] / sum }
    }
    fun largestBox(logits: FloatArray, width: Int, height: Int): DoubleArray? {
        require(width > 0 && height > 0 && logits.size == width * height && logits.all { it.isFinite() })
        val visited = BooleanArray(logits.size)
        val queue = IntArray(logits.size)
        var largest = 0
        var best: DoubleArray? = null
        for (start in logits.indices) {
            if (visited[start] || logits[start] < 0f) continue
            var read = 0; var end = 1
            queue[0] = start; visited[start] = true
            var x0 = width; var y0 = height; var x1 = 0; var y1 = 0
            while (read < end) {
                val i = queue[read++]; val x = i % width; val y = i / width
                x0 = minOf(x0, x); y0 = minOf(y0, y); x1 = maxOf(x1, x + 1); y1 = maxOf(y1, y + 1)
                fun add(j: Int) { if (!visited[j] && logits[j] >= 0f) { visited[j] = true; queue[end++] = j } }
                if (x > 0) add(i - 1)
                if (x + 1 < width) add(i + 1)
                if (y > 0) add(i - width)
                if (y + 1 < height) add(i + width)
            }
            if (end > largest && end >= maxOf(2, (width * height + 99) / 100)) {
                largest = end
                best = doubleArrayOf(x0.toDouble()/width, y0.toDouble()/height, x1.toDouble()/width, y1.toDouble()/height)
            }
        }
        return best
    }
}
