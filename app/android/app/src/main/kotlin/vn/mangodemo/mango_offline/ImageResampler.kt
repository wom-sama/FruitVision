package vn.mangodemo.mango_offline

import kotlin.math.abs
import kotlin.math.max

/** RGB bilinear with antialiasing and per-pass rounding, matching Pillow's training resize. */
object ImageResampler {
    private const val precision = 22
    private const val unit = 1 shl precision
    private const val rounding = 1 shl (precision - 1)
    private data class Weights(val start: Int, val values: IntArray)

    private fun weights(input: Int, output: Int): Array<Weights> {
        val scale = input.toDouble() / output
        val support = max(scale, 1.0)
        return Array(output) { index ->
            val center = (index + .5) * scale
            val start = (center - support + .5).toInt().coerceAtLeast(0)
            val end = (center + support + .5).toInt().coerceAtMost(input)
            val raw = DoubleArray(end - start) { offset ->
                max(0.0, 1.0 - abs((start + offset - center + .5) / support))
            }
            val sum = raw.sum()
            Weights(start, IntArray(raw.size) { (.5 + raw[it] / sum * unit).toInt() })
        }
    }

    private fun sample(pixels: IntArray, offset: Int, stride: Int, weights: Weights): Int {
        var red = rounding; var green = rounding; var blue = rounding
        for (index in weights.values.indices) {
            val pixel = pixels[offset + (weights.start + index) * stride]
            val weight = weights.values[index]
            red += ((pixel ushr 16) and 255) * weight
            green += ((pixel ushr 8) and 255) * weight
            blue += (pixel and 255) * weight
        }
        return (255 shl 24) or ((red shr precision).coerceIn(0, 255) shl 16) or
            ((green shr precision).coerceIn(0, 255) shl 8) or (blue shr precision).coerceIn(0, 255)
    }

    /** Worker-confined, one geometry cache. Returned pixels are borrowed until the next call. */
    class Reusable {
        private var width = 0; private var height = 0
        private var outWidth = 0; private var outHeight = 0
        private var x = emptyArray<Weights>(); private var y = emptyArray<Weights>()
        private var horizontal = IntArray(0); private var output = IntArray(0)

        fun resizeRgb(pixels: IntArray, width: Int, height: Int, outWidth: Int, outHeight: Int): IntArray {
            require(width > 0 && height > 0 && outWidth > 0 && outHeight > 0)
            require(pixels.size.toLong() == width.toLong() * height)
            if (width != this.width || height != this.height || outWidth != this.outWidth || outHeight != this.outHeight) {
                this.width = width; this.height = height; this.outWidth = outWidth; this.outHeight = outHeight
                x = if (width == outWidth) emptyArray() else weights(width, outWidth)
                y = if (height == outHeight) emptyArray() else weights(height, outHeight)
                horizontal = if (x.isEmpty()) IntArray(0) else IntArray(outWidth * height)
                output = if (y.isEmpty()) IntArray(0) else IntArray(outWidth * outHeight)
            }
            val rows = if (x.isEmpty()) pixels else horizontal.also {
                for (row in 0 until height) for (column in 0 until outWidth)
                    it[row * outWidth + column] = sample(pixels, row * width, 1, x[column])
            }
            if (y.isEmpty()) return rows
            for (row in 0 until outHeight) for (column in 0 until outWidth)
                output[row * outWidth + column] = sample(rows, column, outWidth, y[row])
            return output
        }
    }

    fun resizeRgb(pixels: IntArray, width: Int, height: Int, outWidth: Int, outHeight: Int): IntArray {
        require(width > 0 && height > 0 && outWidth > 0 && outHeight > 0)
        require(pixels.size.toLong() == width.toLong() * height)
        val horizontal = if (outWidth == width) pixels else {
            val coefficients = weights(width, outWidth)
            IntArray(outWidth * height) { index ->
                sample(pixels, (index / outWidth) * width, 1, coefficients[index % outWidth])
            }
        }
        if (outHeight == height) return horizontal
        val coefficients = weights(height, outHeight)
        return IntArray(outWidth * outHeight) { index ->
            sample(horizontal, index % outWidth, outWidth, coefficients[index / outWidth])
        }
    }
}
