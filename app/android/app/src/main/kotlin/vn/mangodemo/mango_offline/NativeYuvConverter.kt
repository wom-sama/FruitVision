package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import java.nio.ByteBuffer

/** Read-only YUV planes -> opaque RGBA. Bounds are validated once, not per source pixel. */
internal object NativeYuvConverter {
    data class Plane(val buffer: ByteBuffer, val rowStride: Int, val pixelStride: Int)

    fun convert(y: Plane, u: Plane, v: Plane, left: Int, top: Int, width: Int, height: Int,
                rotation: Int, maxEdge: Int, fullRange: Boolean, bt709: Boolean,
                target: Bitmap? = null): Bitmap {
        require(left >= 0 && top >= 0 && width > 0 && height > 0 && width.toLong()*height <= 16_000_000L)
        require(maxEdge in 1..1600)
        for(plane in listOf(y,u,v)) require(plane.buffer.isDirect && plane.rowStride > 0 && plane.pixelStride > 0)
        val geometry=NativeVideoPixels.geometry(width,height,rotation,maxEdge)
        if (target != null) require(!target.isRecycled && target.isMutable &&
            target.config == Bitmap.Config.ARGB_8888 &&
            target.width == geometry.width && target.height == geometry.height) {
            "YUV target must be a live mutable ARGB bitmap matching output geometry"
        }
        val bitmap=target ?: Bitmap.createBitmap(geometry.width,geometry.height,Bitmap.Config.ARGB_8888)
        try {
            convertNative(bitmap,
                y.buffer,y.buffer.position(),y.buffer.limit(),y.rowStride,y.pixelStride,
                u.buffer,u.buffer.position(),u.buffer.limit(),u.rowStride,u.pixelStride,
                v.buffer,v.buffer.position(),v.buffer.limit(),v.rowStride,v.pixelStride,
                left,top,width,height,rotation,fullRange,bt709)
            return bitmap
        } catch(error: Throwable) {
            // An explicitly supplied target remains owned by its caller.
            if(target == null) bitmap.recycle()
            throw error
        }
    }

    private external fun convertNative(bitmap: Bitmap,
        y: ByteBuffer, yOffset: Int, yLimit: Int, yRow: Int, yPixel: Int,
        u: ByteBuffer, uOffset: Int, uLimit: Int, uRow: Int, uPixel: Int,
        v: ByteBuffer, vOffset: Int, vLimit: Int, vRow: Int, vPixel: Int,
        left: Int, top: Int, width: Int, height: Int, rotation: Int, fullRange: Boolean, bt709: Boolean)
    init { System.loadLibrary("fruit_preprocess") }
}
