package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.io.File
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import kotlin.math.ceil
import kotlin.math.roundToInt

/** Synchronous pull decoder. The activity's inference worker owns its entire lifetime. */
class NativeVideoDecoder(val path: String, private val maxEdge: Int = 1600) : AutoCloseable {
    private val ownerThread = Thread.currentThread()
    private val extractor = MediaExtractor()
    private var codec: MediaCodec? = null
    private var codecStarted = false
    private var resourcesReleased = false
    private var closed = false
    private var inputEnded = false
    private var outputEnded = false
    private var colorFullRange = false
    private var colorBt709 = false
    private var pixelBuffer: Bitmap? = null
    private val outputInfo = MediaCodec.BufferInfo()
    private var previousTimestampUs = -1L
    var framesDecoded = 0
        private set
    val lastTimestampMs get() = if (previousTimestampUs < 0) 0L else previousTimestampUs / 1000
    val info: Map<String, Any>
    private val rotation: Int

    init {
        try {
            require(File(path).isFile) { "Video file not found" }
            require(maxEdge in 1..1600) { "Invalid video decode limit" }
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: throw IllegalArgumentException("No video track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            require(width > 0 && height > 0 && width.toLong() * height <= 16_000_000L) {
                "Video dimensions exceed the bounded decoder capacity"
            }
            rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) format.getInteger(MediaFormat.KEY_ROTATION) else 0
            require(rotation in listOf(0,90,180,270)) { "Unsupported video rotation" }
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            require(durationUs > 0 && durationUs <= 600_000_000L) { "Video must be between zero and ten minutes" }
            val fps = if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) 0.0 else try {
                format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
            } catch (_: ClassCastException) { format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
            require(fps.isFinite() && fps >= 0) { "Invalid video frame rate" }
            val geometry = NativeVideoPixels.geometry(width, height, rotation, maxEdge)
            info = mapOf("durationMs" to ceil(durationUs / 1000.0).toLong(),
                "width" to geometry.width, "height" to geometry.height,
                "sourceWidth" to width, "sourceHeight" to height, "rotationDegrees" to rotation,
                "frameRate" to fps, "estimatedFrameCount" to if (fps > 0) ceil(durationUs / 1e6 * fps).toInt() else 0,
                "mode" to "sequential")
            updateColor(format)
            // Buffer output is not rotated by MediaCodec; conversion applies the original metadata once.
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val opened = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME)))
            codec = opened
            opened.configure(format, null, null, 0)
            opened.start()
            codecStarted = true
        } catch (error: Throwable) {
            try { releaseResources() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    /**
     * Returns every decoded frame in presentation order, without playback/seeks.
     * Pixels are borrowed from this worker-owned decoder, valid until the next
     * nextFrame() or close(). Closing the frame does not recycle those pixels.
     */
    fun nextFrame(): DecodedVideoFrame? {
        checkOwner()
        check(!closed) { "Video sequence closed" }
        try { return decodeNextFrame() }
        catch (error: Throwable) {
            try { close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    private fun decodeNextFrame(): DecodedVideoFrame? {
        if (outputEnded) return null
        val active = requireNotNull(codec)
        val deadline = SystemClock.elapsedRealtime() + 5000L
        while (true) {
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("Video decoding interrupted")
            check(SystemClock.elapsedRealtime() < deadline) { "Video decoder made no progress for five seconds" }
            if (!inputEnded) {
                val inputIndex = active.dequeueInputBuffer(0)
                if (inputIndex >= 0) {
                    val buffer = requireNotNull(active.getInputBuffer(inputIndex))
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        active.queueInputBuffer(inputIndex,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputEnded = true
                    } else {
                        active.queueInputBuffer(inputIndex,0,size,extractor.sampleTime,0)
                        extractor.advance()
                    }
                }
            }
            when (val outputIndex = active.dequeueOutputBuffer(outputInfo, 10_000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> updateColor(active.outputFormat)
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                else -> if (outputIndex >= 0) {
                    val eos = outputInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    var frame: DecodedVideoFrame? = null
                    try {
                        if (outputInfo.size > 0 && outputInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            val image = active.getOutputImage(outputIndex)
                                ?: throw IllegalStateException("Decoder does not expose a YUV frame")
                            image.use {
                                val timestamp = outputInfo.presentationTimeUs
                                require(timestamp >= 0 && timestamp > previousTimestampUs) { "Decoded video timestamps must increase" }
                                val bitmap = toBitmap(it)
                                frame = DecodedVideoFrame(bitmap, timestamp, framesDecoded, recycleOnClose = false)
                                previousTimestampUs = timestamp
                                framesDecoded++
                            }
                        }
                    } finally { active.releaseOutputBuffer(outputIndex, false) }
                    if (eos) {
                        outputEnded = true
                        try { releaseResources() } catch (error: Throwable) { frame?.close(); throw error }
                    }
                    if (frame != null) return frame
                    if (outputEnded) return null
                }
            }
        }
    }

    private fun updateColor(format: MediaFormat) {
        colorFullRange = format.containsKey(MediaFormat.KEY_COLOR_RANGE) &&
            format.getInteger(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL
        colorBt709 = format.containsKey(MediaFormat.KEY_COLOR_STANDARD) &&
            format.getInteger(MediaFormat.KEY_COLOR_STANDARD) == MediaFormat.COLOR_STANDARD_BT709
        if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
            val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
            require(transfer != MediaFormat.COLOR_TRANSFER_ST2084 && transfer != MediaFormat.COLOR_TRANSFER_HLG) {
                "HDR video needs conversion to SDR before fruit analysis"
            }
        }
        if (format.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
            require(format.getInteger(MediaFormat.KEY_COLOR_STANDARD) != MediaFormat.COLOR_STANDARD_BT2020) {
                "BT2020 video needs conversion to SDR before fruit analysis"
            }
        }
    }

    private fun toBitmap(image: Image): Bitmap {
        require(image.format == ImageFormat.YUV_420_888 && image.planes.size == 3) { "Unsupported decoded pixel format" }
        val crop = image.cropRect
        require(crop.width() > 0 && crop.height() > 0 && crop.left >= 0 && crop.top >= 0 &&
            crop.right <= image.width && crop.bottom <= image.height) { "Invalid decoded crop" }
        val yPlane=image.planes[0]; val uPlane=image.planes[1]; val vPlane=image.planes[2]
        val geometry = NativeVideoPixels.geometry(crop.width(),crop.height(),rotation,maxEdge)
        val previous = pixelBuffer
        if (previous != null && (previous.width != geometry.width || previous.height != geometry.height)) {
            if (!previous.isRecycled) previous.recycle()
            pixelBuffer = null
        }
        return NativeYuvConverter.convert(
            NativeYuvConverter.Plane(yPlane.buffer,yPlane.rowStride,yPlane.pixelStride),
            NativeYuvConverter.Plane(uPlane.buffer,uPlane.rowStride,uPlane.pixelStride),
            NativeYuvConverter.Plane(vPlane.buffer,vPlane.rowStride,vPlane.pixelStride),
            crop.left,crop.top,crop.width(),crop.height(),rotation,maxEdge,colorFullRange,colorBt709,
            target = pixelBuffer).also { pixelBuffer = it }
    }

    private fun checkOwner() = check(Thread.currentThread() === ownerThread) { "Video decoder must use its owning worker" }

    private fun releaseResources() {
        if (resourcesReleased) return
        resourcesReleased = true
        val active = codec
        codec = null
        var failure: Throwable? = null
        if (active != null) {
            try { if (codecStarted) active.stop() } catch (error: Throwable) { failure=error }
            try { active.release() } catch (error: Throwable) { if(failure==null) failure=error else failure.addSuppressed(error) }
        }
        try { extractor.release() } catch (error: Throwable) { if(failure==null) failure=error else failure.addSuppressed(error) }
        failure?.let { throw it }
    }

    override fun close() {
        checkOwner()
        if (closed) return
        closed = true
        try { releaseResources() }
        finally {
            val retained = pixelBuffer
            pixelBuffer = null
            if (retained != null && !retained.isRecycled) retained.recycle()
        }
    }
}

class DecodedVideoFrame(val bitmap: Bitmap, val timestampUs: Long, val index: Int,
                        private val recycleOnClose: Boolean = true) : AutoCloseable {
    override fun close() { if (recycleOnClose && !bitmap.isRecycled) bitmap.recycle() }
}

/** Pure coordinate/plane/color operations are covered by JVM tests independently of Android codecs. */
internal object NativeVideoPixels {
    data class Geometry(val sourceWidth: Int, val sourceHeight: Int, val rotation: Int, val width: Int, val height: Int) {
        fun sourceIndex(x: Int, y: Int): Int {
            require(x in 0 until width && y in 0 until height)
            val rw=if(rotation%180==0) sourceWidth else sourceHeight
            val rh=if(rotation%180==0) sourceHeight else sourceWidth
            val rx=((x+.5)*rw/width).toInt().coerceAtMost(rw-1)
            val ry=((y+.5)*rh/height).toInt().coerceAtMost(rh-1)
            return when(rotation) {
                0 -> ry*sourceWidth+rx
                90 -> (sourceHeight-1-rx)*sourceWidth+ry
                180 -> (sourceHeight-1-ry)*sourceWidth+sourceWidth-1-rx
                else -> rx*sourceWidth+sourceWidth-1-ry
            }
        }
    }
    fun geometry(width: Int, height: Int, rotation: Int, maxEdge: Int): Geometry {
        require(width>0 && height>0 && rotation in listOf(0,90,180,270) && maxEdge>0)
        val rw=if(rotation%180==0) width else height
        val rh=if(rotation%180==0) height else width
        val scale=minOf(1.0,maxEdge.toDouble()/maxOf(rw,rh))
        return Geometry(width,height,rotation,maxOf(1,(rw*scale).roundToInt()),maxOf(1,(rh*scale).roundToInt()))
    }
    fun sample(buffer: ByteBuffer, rowStride: Int, pixelStride: Int, x: Int, y: Int): Int {
        require(rowStride>0 && pixelStride>0 && x>=0 && y>=0)
        val index=buffer.position().toLong()+y.toLong()*rowStride+x.toLong()*pixelStride
        require(index < buffer.limit()) { "Decoded plane is truncated" }
        return buffer.get(index.toInt()).toInt() and 255
    }
    fun argb(y: Int, u: Int, v: Int, full: Boolean, bt709: Boolean): Int {
        val du=u-128; val dv=v-128
        val luma=if(full) y*256 else maxOf(0,y-16)*298
        val r=(luma+(if(bt709) if(full) 403 else 459 else if(full) 359 else 409)*dv+128) shr 8
        val g=(luma-(if(bt709) if(full) 48 else 55 else if(full) 88 else 100)*du-
            (if(bt709) if(full) 120 else 136 else if(full) 183 else 208)*dv+128) shr 8
        val b=(luma+(if(bt709) if(full) 475 else 541 else if(full) 454 else 516)*du+128) shr 8
        return 0xFF000000.toInt() or (r.coerceIn(0,255) shl 16) or (g.coerceIn(0,255) shl 8) or b.coerceIn(0,255)
    }
}
