package vn.mangodemo.mango_offline

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Debug
import android.os.SystemClock
import androidx.exifinterface.media.ExifInterface
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.exp

/** All calls run on the activity-owned single worker, never the Flutter UI thread. */
class NativeInferenceEngine(private val context: Context) : AutoCloseable {
    private val environment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private var options: OrtSession.SessionOptions? = null
    private var metadata: JSONObject? = null
    private var graderContract: GraderOutputContract? = null
    private var retriever: MediaMetadataRetriever? = null
    private var videoPath: String? = null
    private var videoSequence: NativeVideoDecoder? = null
    private var videoPreviewPath: String? = null
    private var videoPreviewPssMb: Double? = null
    private var lastVideoPreviewNs = 0L
    val videoSequenceOpen get() = videoSequence != null
    private val target = 224
    private val maskSize = 56
    private val maxDecodeEdge = 1600
    private val tensorBuffer = FloatBuffer.allocate(3 * target * target)
    private val pixels = IntArray(target * target)
    private val mean = floatArrayOf(.485f, .456f, .406f)
    private val std = floatArrayOf(.229f, .224f, .225f)
    private var previewIndex = 0
    private var threads = 1
    private var detector: NativeDetector? = null
    private var directStageMetadata: JSONObject? = null

    private fun currentDetector(): NativeDetector = detector ?: NativeDetector(context, threads).also { detector = it }

    fun prepare(multiObject: Boolean = false): Map<String, Any> {
        val started = SystemClock.elapsedRealtimeNanos()
        val directMeta=directStageMetadata ?: context.assets.open("detector_metadata.json").bufferedReader().use { JSONObject(it.readText()) }
        if (directMeta.optString("mode")=="direct_fruit_stages") return prepareDirect(directMeta,started)
        if (session == null) {
            val meta = context.assets.open("model_metadata.json").bufferedReader().use { JSONObject(it.readText()) }
            val contract = GraderOutputContract.fromMetadata(jsonMap(meta))
            val directory = File(context.filesDir, "models").apply { mkdirs() }
            val file = File(directory, "mango_student.onnx")
            val expected = meta.getString("model_sha256")
            if (!file.isFile || sha256(file) != expected) {
                val temp = File(directory, "model.tmp")
                try {
                    context.assets.open("mango_student.onnx").use { source -> temp.outputStream().use { source.copyTo(it) } }
                    require(sha256(temp) == expected) { "Model SHA-256 mismatch" }
                    require(temp.renameTo(file)) { "Cannot install bundled model" }
                } finally { if (temp.exists()) temp.delete() }
            }
            require(meta.getInt("input_size") == target && (!contract.hasMask || meta.getInt("mask_size") == maskSize)) { "Unsupported model shape" }
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            threads = if (manager.isLowRamDevice) 1 else (Runtime.getRuntime().availableProcessors() - 1).coerceIn(1, 4)
            val configured = OrtSession.SessionOptions().apply {
                setIntraOpNumThreads(threads)
                setInterOpNumThreads(1)
                setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                addConfigEntry("session.intra_op.allow_spinning", "0")
                addConfigEntry("session.inter_op.allow_spinning", "0")
            }
            var loaded: OrtSession? = null
            try {
                loaded = environment.createSession(file.absolutePath, configured)
                require(loaded.inputNames == setOf("image")) { "Unsupported model inputs" }
                val info = loaded.inputInfo.getValue("image").info as TensorInfo
                require(info.type == OnnxJavaType.FLOAT && info.shape.contentEquals(longArrayOf(1, 3, 224, 224))) { "Invalid model tensor contract" }
                val outputShapes = loaded.outputInfo.mapValues { (_, node) ->
                    (node.info as? TensorInfo)?.shape ?: throw IllegalArgumentException("Invalid model output tensor")
                }
                val floatOutputs = loaded.outputInfo.filterValues {
                    (it.info as? TensorInfo)?.type == OnnxJavaType.FLOAT
                }.keys
                contract.validateGraph(outputShapes, floatOutputs)
                session = loaded; options = configured; metadata = meta; graderContract = contract
            } catch (error: Exception) {
                loaded?.close(); configured.close()
                throw error
            }
        }
        val sample = File(context.filesDir, "demo_mango.jpg")
        if (!sample.exists()) context.assets.open("demo_mango.jpg").use { input -> sample.outputStream().use { input.copyTo(it) } }
        val meta = metadata!!
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
        val sceneMode = multiObject || !graderContract!!.hasMask || graderContract!!.speciesThreshold != null
        val detection = if (sceneMode) currentDetector() else null
        val multiSample = if (sceneMode) File(context.filesDir, "demo_multi_mango.png").also { file ->
            if (!file.isFile) context.assets.open("demo_multi_mango.png").use { input -> file.outputStream().use { input.copyTo(it) } }
        } else null
        return mapOf("modelName" to meta.optString("model_name", if (!graderContract!!.hasMask)
                "Fruit detector + MobileNetV3 · skin stages" else if (multiObject)
                "SSDLite mango + MobileNetV3 · V18.6" else "MobileNetV3 · distillation V18.6"),
            "modelBytes" to File(context.filesDir, "models/mango_student.onnx").length() + (detection?.modelBytes ?: 0L),
            "modelSha256" to meta.getString("model_sha256"), "threads" to threads,
            "abi" to Build.SUPPORTED_ABIS.first(), "offline" to true,
            "samplePath" to sample.absolutePath,
            "classLabels" to (0 until 5).map { meta.getJSONArray("class_labels").getString(it) },
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}", "androidSdk" to Build.VERSION.SDK_INT,
            "totalMemoryMb" to memory.totalMem / 1048576.0, "nativePssMb" to Debug.getPss() / 1024.0,
            "metrics" to jsonMap(meta.optJSONObject("metrics") ?: JSONObject()),
            "loadMs" to (SystemClock.elapsedRealtimeNanos() - started) / 1e6,
            "supportedSpecies" to graderContract!!.supportedSpecies.toList(),
            "graderMode" to if (graderContract!!.hasMask) "legacy_mask" else "classification_only") +
            if (detection == null) emptyMap() else mapOf("detectorModelSha256" to detection.modelSha256,
                "multiSamplePath" to requireNotNull(multiSample).absolutePath)
    }

    private fun prepareDirect(meta: JSONObject, started: Long): Map<String,Any> {
        val manager=context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory=ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
        threads=RuntimeAccelerationPolicy.workerThreads(Runtime.getRuntime().availableProcessors(),
            manager.isLowRamDevice || memory.lowMemory || memory.availMem < 256L * 1024 * 1024)
        val detection=currentDetector()
        require(detection.stageLabels==listOf("Xanh / chưa chín","Chín"))
        directStageMetadata=meta
        val sample=File(context.filesDir,"demo_fruit_stage.jpg")
        context.assets.open("demo_mango.jpg").use { input -> sample.outputStream().use { input.copyTo(it) } }
        val multi=File(context.filesDir,"demo_fruit_multi_stage.png")
        context.assets.open("demo_multi_mango.png").use { input -> multi.outputStream().use { input.copyTo(it) } }
        return mapOf("modelName" to meta.getString("model_name"),"modelBytes" to detection.modelBytes,
            "modelSha256" to detection.modelSha256,"detectorModelSha256" to detection.modelSha256,
            "threads" to threads,"abi" to Build.SUPPORTED_ABIS.first(),"offline" to true,
            "samplePath" to sample.absolutePath,"multiSamplePath" to multi.absolutePath,
            "classLabels" to detection.stageLabels,"supportedSpecies" to listOf("banana","mango"),
            "graderMode" to "detection_stages","device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "androidSdk" to Build.VERSION.SDK_INT,"totalMemoryMb" to memory.totalMem/1048576.0,
            "nativePssMb" to Debug.getPss()/1024.0,"loadMs" to (SystemClock.elapsedRealtimeNanos()-started)/1e6,
            "metrics" to jsonMap(meta.optJSONObject("metrics") ?: JSONObject()))
    }

    fun analyzeImage(path: String, multiObject: Boolean = false): Map<String, Any> {
        val started = SystemClock.elapsedRealtimeNanos()
        require(File(path).isFile) { "Image file not found" }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Cannot decode image" }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxDecodeEdge) sample *= 2
        val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
            inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: throw IllegalArgumentException("Cannot decode image")
        var oriented = decoded
        try {
            val matrix = Matrix()
            val orientation = ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(270f); matrix.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(270f)
            }
            if (!matrix.isIdentity) oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            return if (usesScene(multiObject)) analyzeScene(oriented, started, true) else analyzeBitmap(oriented, started)
        } finally {
            if (oriented !== decoded) oriented.recycle()
            decoded.recycle()
        }
    }

    private fun video(path: String): MediaMetadataRetriever {
        require(File(path).isFile) { "Video file not found" }
        if (videoPath != path) {
            retriever?.release(); retriever = null; videoPath = null
            val opened = MediaMetadataRetriever()
            try { opened.setDataSource(path) } catch (error: Exception) { opened.release(); throw error }
            retriever = opened; videoPath = path
        }
        return retriever!!
    }

    fun videoInfo(path: String): Map<String, Any> {
        val opened = video(path)
        val duration = opened.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        require(duration > 0) { "Video has no valid duration" }
        return mapOf("durationMs" to duration,
            "width" to (opened.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0),
            "height" to (opened.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0))
    }

    fun openVideoSequence(path: String): Map<String, Any> {
        closeVideoSequence()
        retriever?.release(); retriever=null; videoPath=null
        val opened=NativeVideoDecoder(path,maxDecodeEdge)
        videoSequence=opened
        return opened.info
    }

    /** Pull one real decoded frame; UI previews are throttled independently of model/tracking cadence. */
    fun nextVideoFrame(path: String, multiObject: Boolean = false): Map<String, Any> {
        val sequence=checkNotNull(videoSequence) { "Video sequence is not open" }
        require(path==sequence.path) { "Video sequence path changed" }
        val started=SystemClock.elapsedRealtimeNanos()
        try {
            val frame=sequence.nextFrame() ?: return mapOf("endOfStream" to true,
                "framesDecoded" to sequence.framesDecoded,"lastTimestampMs" to sequence.lastTimestampMs)
            frame.use {
                val decodedAt=SystemClock.elapsedRealtimeNanos()
                val previewUpdated=videoPreviewPath==null || decodedAt-lastVideoPreviewNs>=200_000_000L
                val analyzed=if(usesScene(multiObject)) analyzeScene(it.bitmap,started,previewUpdated)
                    else analyzeBitmap(it.bitmap,started,previewUpdated)
                if(previewUpdated) {
                    videoPreviewPath=analyzed["previewPath"] as String
                    videoPreviewPssMb=(analyzed["nativePssMb"] as Number).toDouble()
                    lastVideoPreviewNs=SystemClock.elapsedRealtimeNanos()
                }
                return analyzed+mapOf("timestampMs" to it.timestampUs/1000,"frameIndex" to it.index,
                    "endOfStream" to false,"previewUpdated" to previewUpdated,
                    "previewPath" to requireNotNull(videoPreviewPath),"nativePssMb" to requireNotNull(videoPreviewPssMb),
                    "decodeMs" to (decodedAt-started)/1e6)
            }
        } catch(error: Throwable) {
            try { closeVideoSequence() } catch(cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    fun closeVideoSequence() {
        val opened=videoSequence
        videoSequence=null
        videoPreviewPath=null; videoPreviewPssMb=null; lastVideoPreviewNs=0L
        opened?.close()
    }

    fun analyzeVideoFrame(path: String, timeMs: Long, multiObject: Boolean = false): Map<String, Any> {
        val started = SystemClock.elapsedRealtimeNanos()
        val info = videoInfo(path)
        require(timeMs in 0 until (info["durationMs"] as Long)) { "Frame timestamp outside video" }
        val opened = video(path)
        val bitmap = if (Build.VERSION.SDK_INT >= 27) {
            val w = info["width"] as Int; val h = info["height"] as Int
            require(w > 0 && h > 0) { "Invalid video dimensions" }
            val ratio = minOf(1.0, maxDecodeEdge.toDouble() / maxOf(w, h))
            opened.getScaledFrameAtTime(timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST,
                maxOf(1, (w * ratio).toInt()), maxOf(1, (h * ratio).toInt()))
        } else {
            require((info["width"] as Int).toLong() * (info["height"] as Int) <= 12_000_000) { "Video resolution too large on Android 8.0" }
            opened.getFrameAtTime(timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
        } ?: throw IllegalArgumentException("Cannot decode frame at $timeMs ms")
        try { return (if (usesScene(multiObject)) analyzeScene(bitmap, started, true) else analyzeBitmap(bitmap, started)) + mapOf("timestampMs" to timeMs) }
        finally { bitmap.recycle() }
    }

    /** Caller owns bitmap; live frames never write JPEG previews or sample PSS per frame. */
    fun analyzeCameraBitmap(bitmap: Bitmap, started: Long, multiObject: Boolean = false): Map<String, Any> =
        if (usesScene(multiObject)) analyzeScene(bitmap, started, false) else analyzeBitmap(bitmap, started, savePreview = false)

    private fun usesScene(multiObject: Boolean): Boolean {
        if (session == null && directStageMetadata==null) prepare()
        return directStageMetadata!=null || multiObject || !graderContract!!.hasMask || graderContract!!.speciesThreshold != null
    }

    private fun analyzeScene(bitmap: Bitmap, started: Long, savePreview: Boolean): Map<String, Any> {
        if (session == null && directStageMetadata==null) prepare()
        val detection = currentDetector()
        val found = detection.detect(bitmap)
        val classificationStarted = SystemClock.elapsedRealtimeNanos()
        var modelMs = found.modelMs
        val objects = found.selection.boxes.mapNotNull { region ->
            if (directStageMetadata!=null) {
                directStageObject(region)
            } else {
            graderContract!!.routeSceneObject(region.box, region.score, region.species) {
                val rectangle = DetectionMath.crop(region.box, bitmap.width, bitmap.height, detection.roiContext)
                val crop = Bitmap.createBitmap(bitmap, rectangle[0], rectangle[1], rectangle[2]-rectangle[0], rectangle[3]-rectangle[1])
                val grading = try { analyzeBitmap(crop, SystemClock.elapsedRealtimeNanos(), false, sceneCrop = true) }
                    finally { if (crop !== bitmap) crop.recycle() }
                modelMs += grading["modelMs"] as Double
                grading
            }
            }
        }
        val classificationMs = (SystemClock.elapsedRealtimeNanos() - classificationStarted) / 1e6
        val elapsed = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
        // Legacy scalar fields are wire compatibility only; scene UI uses objects, never a global grade.
        val result = mutableMapOf<String, Any>(
            "objects" to objects, "detectionLimitReached" to found.selection.limitReached,
            "imageWidth" to bitmap.width, "imageHeight" to bitmap.height,
            "detectorMs" to found.elapsedMs, "classificationMs" to classificationMs,
            "modelMs" to modelMs, "preprocessMs" to (elapsed-modelMs).coerceAtLeast(0.0), "elapsedMs" to elapsed)
        result["runtimeProvider"] = detection.runtimeProvider
        result["runtimeSelection"] = detection.runtimeSelection
        result["runtimeTuningMs"] = detection.runtimeTuningMs
        if(directStageMetadata!=null) {
            result["gradeScheme"]="source_two_stage"
            result.putAll(directStageSummary(objects))
        } else result.putAll(graderContract!!.sceneSummary(objects))
        if (savePreview) {
            val preview = File(context.cacheDir, "preview_${previewIndex++ % 2}.jpg")
            preview.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
            result["previewPath"] = preview.absolutePath; result["nativePssMb"] = Debug.getPss() / 1024.0
            result["elapsedMs"] = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
        }
        return result
    }

    private fun analyzeBitmap(bitmap: Bitmap, started: Long, savePreview: Boolean = true,
                              sceneCrop: Boolean = false): Map<String, Any> {
        if (session == null) prepare()
        val contract = graderContract!!
        val includePresence = sceneCrop && contract.presenceThreshold != null
        val includeSpecies = sceneCrop && contract.speciesThreshold != null
        val transform = InferenceMath.letterbox(bitmap.width, bitmap.height, target)
        val sourcePixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(sourcePixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val scaled = ImageResampler.resizeRgb(sourcePixels, bitmap.width, bitmap.height,
            transform.scaledWidth, transform.scaledHeight)
        pixels.fill(0xFF7C7468.toInt())
        for (row in 0 until transform.scaledHeight) {
            scaled.copyInto(pixels, (row + transform.top) * target + transform.left,
                row * transform.scaledWidth, (row + 1) * transform.scaledWidth)
        }
            tensorBuffer.clear()
            var redMin = 255; var redMax = 0; var greenMin = 255; var greenMax = 0; var blueMin = 255; var blueMax = 0
            for (channel in 0..2) for (i in pixels.indices) {
                val value = (pixels[i] shr (16 - channel * 8)) and 255
                tensorBuffer.put((value / 255f - mean[channel]) / std[channel])
                val x = i % target; val y = i / target
                if (x in transform.left until transform.left + transform.scaledWidth && y in transform.top until transform.top + transform.scaledHeight) {
                    when (channel) {
                        0 -> { redMin = minOf(redMin, value); redMax = maxOf(redMax, value) }
                        1 -> { greenMin = minOf(greenMin, value); greenMax = maxOf(greenMax, value) }
                        2 -> { blueMin = minOf(blueMin, value); blueMax = maxOf(blueMax, value) }
                    }
                }
            }
            tensorBuffer.flip()
            val modelStarted = SystemClock.elapsedRealtimeNanos()
            var logits: FloatArray
            val mask = if (includePresence || includeSpecies || !contract.hasMask) null else FloatArray(maskSize * maskSize)
            var presenceLogits: FloatArray? = null
            var speciesLogits: FloatArray? = null
            val selectedOutputs = if (includePresence || includeSpecies) contract.sceneOutputNames else contract.wholeImageOutputNames
            OnnxTensor.createTensor(environment, tensorBuffer, longArrayOf(1, 3, 224, 224)).use { tensor ->
                session!!.run(mapOf("image" to tensor), selectedOutputs).use { output ->
                    val classes = output.get("logits").get() as OnnxTensor
                    logits = FloatArray(5); classes.floatBuffer.get(logits)
                    if (includePresence) {
                        presenceLogits = FloatArray(2).also {
                            (output.get("mango_logits").get() as OnnxTensor).floatBuffer.get(it)
                        }
                    } else if (includeSpecies) {
                        speciesLogits = FloatArray(7).also {
                            (output.get("species_logits").get() as OnnxTensor).floatBuffer.get(it)
                        }
                    } else if (mask != null) {
                        (output.get("mask_logits").get() as OnnxTensor).floatBuffer.get(mask)
                    }
                }
            }
            val modelEnded = SystemClock.elapsedRealtimeNanos()
            val probabilities = InferenceMath.softmax(logits, metadata!!.optDouble("temperature", 1.0))
            val label = probabilities.indices.maxBy { probabilities[it] }
            val flat = maxOf(redMax - redMin, greenMax - greenMin, blueMax - blueMin) < 6
            // Ignore padding in the mask rather than treating letterbox as fruit evidence.
            if (mask != null) for (y in 0 until maskSize) for (x in 0 until maskSize) {
                val px = (x + .5) * target / maskSize
                val py = (y + .5) * target / maskSize
                if (px < transform.left || px >= transform.left + transform.scaledWidth || py < transform.top || py >= transform.top + transform.scaledHeight) mask[y * maskSize + x] = -20f
            }
            val box = if (flat || mask == null) null else InferenceMath.largestBox(mask, maskSize, maskSize)?.let { transform.toOriginal(it) }
            val status = if (contract.hasMask && !includePresence && !includeSpecies && box == null) "NO_MANGO"
                else if (probabilities[label] < .5) "UNCERTAIN" else "OK"
            val result = mutableMapOf<String, Any>("status" to status,
                "classId" to label, "probabilities" to probabilities.toList(),
                "imageWidth" to bitmap.width, "imageHeight" to bitmap.height,
                "modelMs" to (modelEnded - modelStarted) / 1e6,
                "preprocessMs" to (modelStarted - started) / 1e6,
                "elapsedMs" to (SystemClock.elapsedRealtimeNanos() - started) / 1e6)
            if (includePresence) result["mangoProbability"] = contract.mangoProbability(presenceLogits!!)
            if (includeSpecies) result["speciesLogits"] = speciesLogits!!.map { it.toDouble() }
            if (savePreview) {
                val preview = File(context.cacheDir, "preview_${previewIndex++ % 2}.jpg")
                preview.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                result["previewPath"] = preview.absolutePath
                result["nativePssMb"] = Debug.getPss() / 1024.0
                result["elapsedMs"] = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
            }
            if (box != null) result["box"] = box.toList()
            return result
    }

    override fun close() {
        closeVideoSequence()
        detector?.close(); detector = null
        directStageMetadata = null
        retriever?.release(); retriever = null; videoPath = null
        session?.close(); session = null
        options?.close(); options = null; metadata = null; graderContract = null
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key -> jsonValue(json.get(key)) }
    private fun jsonValue(value: Any?): Any? = when (value) {
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}

/** Session-output and ROI wire contract; grade confidence is not mango presence. */
internal class GraderOutputContract private constructor(val presenceThreshold: Double?, val hasMask: Boolean,
    val supportedSpecies: Set<String>, val speciesThreshold: Double? = null, val otherSpeciesThreshold: Double? = null) {
    private val outputShapes = linkedMapOf("logits" to longArrayOf(1, 5)).also {
        if (hasMask) it["mask_logits"] = longArrayOf(1, 1, 56, 56)
        if (presenceThreshold != null) it["mango_logits"] = longArrayOf(1, 2)
        if (speciesThreshold != null) it["species_logits"] = longArrayOf(1, 7)
    }
    val wholeImageOutputNames: Set<String> = if (hasMask) setOf("logits", "mask_logits") else setOf("logits")
    val sceneOutputNames: Set<String> = when {
        speciesThreshold != null -> setOf("logits","species_logits")
        presenceThreshold != null -> setOf("logits","mango_logits")
        else -> wholeImageOutputNames
    }

    fun routeSceneObject(box: DoubleArray, detectionScore: Double, species: String,
        grade: () -> Map<String, Any>): Map<String, Any>? {
        require(box.size == 4 && box.all { it.isFinite() && it in 0.0..1.0 } && box[0] < box[2] && box[1] < box[3] &&
            detectionScore.isFinite() && detectionScore in 0.0..1.0 && species.isNotBlank()) { "Invalid detected object" }
        if (speciesThreshold != null) return sceneObject(box,detectionScore,grade())
        if (species !in supportedSpecies) return mapOf("box" to box.toList(), "detectionScore" to detectionScore,
            "species" to species, "status" to "UNSUPPORTED_SPECIES")
        return sceneObject(box, detectionScore, grade())?.plus("species" to species)
    }

    fun sceneSummary(objects: List<Map<String, Any>>): Map<String, Any> {
        val firstGraded = objects.firstOrNull { it.containsKey("classId") }
        val result = mutableMapOf<String, Any>("status" to if (objects.isEmpty()) {
            if (hasMask && speciesThreshold == null) "NO_MANGO" else "NO_FRUIT"
        } else if (firstGraded == null) "UNSUPPORTED_SPECIES"
        else if (objects.any { it["status"] == "UNCERTAIN" }) "UNCERTAIN" else "OK")
        if (firstGraded != null) {
            result["classId"] = firstGraded.getValue("classId")
            result["probabilities"] = firstGraded.getValue("probabilities")
        } else if (hasMask && speciesThreshold == null && objects.isEmpty()) {
            result["classId"] = 0; result["probabilities"] = List(5) { 0.0 }
        }
        return result
    }

    fun validateGraph(shapes: Map<String, LongArray>, floatOutputs: Set<String>) {
        require(shapes.keys == outputShapes.keys && floatOutputs == outputShapes.keys &&
            outputShapes.all { (name, shape) -> shapes.getValue(name).contentEquals(shape) }) {
            "Model outputs disagree with grader metadata"
        }
    }

    fun mangoProbability(logits: FloatArray): Double {
        require(presenceThreshold != null && logits.size == 2 && logits.all { it.isFinite() }) {
            "Invalid binary mango logits"
        }
        val maximum = logits.max().toDouble()
        val notMango = exp(logits[0].toDouble() - maximum)
        val mango = exp(logits[1].toDouble() - maximum)
        return mango / (notMango + mango)
    }

    fun sceneObject(box: DoubleArray, detectionScore: Double, grading: Map<String, Any>): Map<String, Any>? {
        var speciesMangoProbability: Double? = null
        if (speciesThreshold != null) {
            val raw=grading["speciesLogits"] as? List<*> ?: throw IllegalArgumentException("Missing species logits")
            val logits=raw.map { (it as? Number)?.toDouble() ?: throw IllegalArgumentException("Invalid species logits") }
            require(logits.size==7 && logits.all { it.isFinite() }) { "Invalid species logits" }
            val maximum=logits.max()
            val numerator=logits.map { exp(it-maximum) }
            val probability=numerator.map { it/numerator.sum() }
            val winner=probability.indices.maxBy { probability[it] }
            if (winner==6) return null
            if (winner!=0) {
                if (probability[winner] < otherSpeciesThreshold!!) return null
                return mapOf("box" to box.toList(),"detectionScore" to detectionScore,
                    "species" to speciesNames[winner],"speciesConfidence" to probability[winner],"status" to "UNSUPPORTED_SPECIES")
            }
            if (probability[0] < speciesThreshold) return null
            speciesMangoProbability=probability[0]
        }
        val values = grading["probabilities"] as? List<*> ?: throw IllegalArgumentException("Missing grade probabilities")
        val probabilities = values.map { (it as? Number)?.toDouble()
            ?: throw IllegalArgumentException("Invalid grade probability") }
        val classId = grading["classId"] as? Int ?: throw IllegalArgumentException("Missing grade class")
        require(probabilities.size == 5 && probabilities.all { it.isFinite() && it in 0.0..1.0 } &&
            abs(probabilities.sum() - 1.0) <= 1e-6 && classId in 0..4 &&
            classId == probabilities.indices.maxBy { probabilities[it] }) { "Invalid five-grade prediction" }
        val mango = if (presenceThreshold == null) {
            require(!grading.containsKey("mangoProbability")) { "Undeclared mango presence output" }
            null
        } else {
            val probability = (grading["mangoProbability"] as? Number)?.toDouble()
                ?: throw IllegalArgumentException("Missing mango presence probability")
            require(probability.isFinite() && probability in 0.0..1.0) { "Invalid mango presence probability" }
            if (probability < presenceThreshold) return null
            probability
        }
        // Legacy scene crops also ignore the old mask-derived whole-image status.
        val result = mapOf("box" to box.toList(), "detectionScore" to detectionScore,
            "classId" to classId, "probabilities" to probabilities,
            "status" to if (probabilities[classId] >= .5) "OK" else "UNCERTAIN")
        return when {
            speciesMangoProbability != null -> result+mapOf("species" to "mango","mangoProbability" to speciesMangoProbability)
            mango != null -> result+("mangoProbability" to mango)
            else -> result
        }
    }

    companion object {
        private val speciesNames=listOf("mango","apple","guava","papaya","banana","orange","other_or_background")
        fun fromMetadata(metadata: Map<String, Any?>): GraderOutputContract {
            val hasMask = if (metadata.containsKey("grader_mode")) {
                require(metadata["grader_mode"] == "classification_only") { "Invalid grader mode" }
                false
            } else true
            val supported = if (hasMask) {
                if (metadata.containsKey("supported_species")) require(metadata["supported_species"] == listOf("mango")) {
                    "Legacy mango grader cannot grade other species"
                }
                setOf("mango")
            } else {
                require(metadata["supported_species"] == listOf("banana") && !metadata.containsKey("presence_head")) {
                    "Invalid classification-only species or presence contract"
                }
                setOf("banana")
            }
            val threshold = if (metadata.containsKey("presence_head")) {
                val head = metadata["presence_head"] as? Map<*, *>
                    ?: throw IllegalArgumentException("Invalid declared presence head")
                val value = (head["threshold"] as? Number)?.toDouble()
                    ?: throw IllegalArgumentException("Missing finite presence threshold")
                require(value.isFinite() && value in 0.0..1.0 &&
                    head["class_labels"] == listOf("not_mango", "mango") &&
                    head["output_name"] == "mango_logits") { "Invalid presence head contract" }
                value
            } else null
            var speciesThreshold: Double? = null
            var otherSpeciesThreshold: Double? = null
            if (metadata.containsKey("species_head")) {
                require(hasMask && threshold==null && supported==setOf("mango")) { "Species and presence heads are exclusive" }
                val head=metadata["species_head"] as? Map<*,*> ?: throw IllegalArgumentException("Invalid species head")
                require(head["output_name"]=="species_logits" && head["class_labels"]==speciesNames && head["mango_index"]==0) {
                    "Invalid species head namespace"
                }
                speciesThreshold=(head["threshold"] as? Number)?.toDouble() ?: throw IllegalArgumentException("Missing species threshold")
                otherSpeciesThreshold=(head["other_species_threshold"] as? Number)?.toDouble()
                    ?: throw IllegalArgumentException("Missing other species threshold")
                require(speciesThreshold.isFinite() && speciesThreshold in 0.0..1.0 &&
                    otherSpeciesThreshold.isFinite() && otherSpeciesThreshold in 0.0..1.0) { "Invalid species threshold" }
            }
            val contract = GraderOutputContract(threshold, hasMask, supported,speciesThreshold,otherSpeciesThreshold)
            require(metadata["output_names"] == contract.outputShapes.keys.toList()) { "Invalid grader metadata outputs" }
            val shapes = metadata["output_shapes"] as? List<*>
                ?: throw IllegalArgumentException("Missing grader metadata output shapes")
            require(shapes.size == contract.outputShapes.size) { "Invalid grader metadata output shapes" }
            for ((actual, expected) in shapes.zip(contract.outputShapes.values)) {
                val dimensions = actual as? List<*> ?: throw IllegalArgumentException("Invalid grader metadata shape")
                require(dimensions.size == expected.size && dimensions.zip(expected.toList()).all { (value, size) ->
                    value is Number && value.toDouble() == size.toDouble()
                }) { "Invalid grader metadata shape" }
            }
            return contract
        }
    }
}
