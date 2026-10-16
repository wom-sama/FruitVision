package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import androidx.camera.core.ImageProxy

/** Owned upright crop plus inverse geometry to the original, unrotated camera buffer. */
class CameraFrame private constructor(val bitmap: Bitmap, private val toBuffer: Matrix) : AutoCloseable {
    fun toBufferBox(box: DoubleArray): RectF {
        require(box.size == 4 && box.all { it.isFinite() && it in 0.0..1.0 })
        return RectF((box[0] * bitmap.width).toFloat(), (box[1] * bitmap.height).toFloat(),
            (box[2] * bitmap.width).toFloat(), (box[3] * bitmap.height).toFloat()).also { toBuffer.mapRect(it) }
    }
    override fun close() = bitmap.recycle()
    companion object {
        fun fromProxy(image: ImageProxy): CameraFrame {
            // CameraX native converter respects YUV row/pixel strides, no JPEG round-trip.
            val full = image.toBitmap()
            var transferred = false
            try {
                val crop = image.cropRect
                val rotation = image.imageInfo.rotationDegrees
                if (rotation == 0 && crop.left == 0 && crop.top == 0 &&
                    crop.right == full.width && crop.bottom == full.height) {
                    // This converter result is already owned, unlike fromBitmap's
                    // borrowed input. Identity geometry can transfer it directly.
                    val frame = CameraFrame(full, Matrix())
                    transferred = true
                    return frame
                }
                return fromBitmap(full, crop, rotation)
            } finally { if (!transferred) full.recycle() }
        }
        fun fromBitmap(source: Bitmap, crop: Rect, rotation: Int): CameraFrame {
            require(rotation in listOf(0, 90, 180, 270))
            require(crop.width() > 0 && crop.height() > 0 && crop.left >= 0 && crop.top >= 0 &&
                crop.right <= source.width && crop.bottom <= source.height)
            val rotate = Matrix().apply { setRotate(rotation.toFloat()) }
            val bounds = RectF(0f, 0f, crop.width().toFloat(), crop.height().toFloat())
            rotate.mapRect(bounds)
            rotate.postTranslate(-bounds.left, -bounds.top)
            val inverse = Matrix()
            check(rotate.invert(inverse))
            inverse.postTranslate(crop.left.toFloat(), crop.top.toFloat())
            var upright = Bitmap.createBitmap(source, crop.left, crop.top, crop.width(), crop.height(), rotate, false)
            // createBitmap may alias source for the identity case; ownership must stay explicit.
            if (upright === source) upright = source.copy(Bitmap.Config.ARGB_8888, false)
            return CameraFrame(upright, inverse)
        }
    }
}
