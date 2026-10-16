package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Worker-confined exact RGB resize/letterbox/packing. Transparent pixels use Kotlin. */
internal class NativePreprocessor : AutoCloseable {
    private var handle = create()
    fun prepare(bitmap: Bitmap, destination: ByteBuffer, target: Int, width: Int, height: Int, left: Int, top: Int): Boolean {
        check(handle != 0L) { "Preprocessor is closed" }
        require(destination.isDirect && !destination.isReadOnly && destination.order() == ByteOrder.nativeOrder())
        require(target in 1..640 && width in 1..target && height in 1..target &&
            left >= 0 && top >= 0 && left + width <= target && top + height <= target)
        require(destination.capacity().toLong() >= 3L * target * target * 4)
        if (bitmap.config != Bitmap.Config.ARGB_8888 || bitmap.colorSpace?.isSrgb == false) return false
        return prepareNative(handle, bitmap, destination, target, width, height, left, top)
    }
    override fun close() { if (handle != 0L) { destroy(handle); handle = 0L } }
    private external fun create(): Long
    private external fun destroy(handle: Long)
    private external fun prepareNative(handle: Long, bitmap: Bitmap, destination: ByteBuffer,
        target: Int, width: Int, height: Int, left: Int, top: Int): Boolean
    companion object { init { System.loadLibrary("fruit_preprocess") } }
}
