package vn.mangodemo.mango_offline

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** One sequential detector session, owned by the same worker as the crop grader. */
class NativeDetector(private val context: Context, private val threads: Int) : AutoCloseable {
    private val environment = OrtEnvironment.getEnvironment()
    private val metadata = context.assets.open("detector_metadata.json").bufferedReader().use { JSONObject(it.readText()) }
    private val contract = DetectorOutputContract.fromMetadata(metadata.keys().asSequence()
        .filter { it in setOf("species_names", "letterbox_alignment", "letterbox_rounding", "padding_rgb", "nms_mode", "stage_labels", "max_classified_objects", "geometry_only_grade_abstention") }.associateWith { key ->
            when (val value = metadata.get(key)) {
                is JSONArray -> (0 until value.length()).map { value.get(it) }
                JSONObject.NULL -> null
                else -> value
            }
        })
    private val inputShape = metadata.getJSONArray("input_shape").let { shape -> LongArray(shape.length()) { shape.getLong(it) } }
    private val target = InferenceMath.detectorInputSize(inputShape)
    // ORT can borrow a direct native-order buffer instead of copying ~2.6MiB each frame.
    private val tensorMemory = ByteBuffer.allocateDirect(4 * 3 * target * target).order(ByteOrder.nativeOrder())
    private val tensor = tensorMemory.asFloatBuffer()
    private var nativePreprocessor: NativePreprocessor? = null
    private val pixels = IntArray(target * target)
    private val planarPixels = FloatArray(3 * target * target)
    private var sourcePixels = IntArray(0)
    private val resampler = ImageResampler.Reusable()
    private var options = OrtSession.SessionOptions().apply {
        setIntraOpNumThreads(threads); setInterOpNumThreads(1)
        setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
        setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        addConfigEntry("session.intra_op.allow_spinning", "0")
        addConfigEntry("session.inter_op.allow_spinning", "0")
    }
    private var session: OrtSession
    private val inputTensor: OnnxTensor
    private val inputs: Map<String, OnnxTensor>
    private val rawBoxes: FloatArray
    private val rawScores: FloatArray
    private val rawSpecies: LongArray?
    private val rawStages: LongArray?
    private val rawStageScores: FloatArray?
    val runtimeProvider = if (threads > 2) "CPU ($threads threads)" else "CPU"
    val runtimeSelection = "CPU: reused session; no blocking provider search during analysis"
    val runtimeTuningMs = 0.0
    val modelSha256: String get() = metadata.getString("model_sha256")
    val modelBytes: Long
    val roiContext: Double get() = metadata.getDouble("roi_context")
    val stageLabels: List<String> get() = contract.stageLabels
    data class Result(val selection: DetectionMath.Selection, val modelMs: Double, val elapsedMs: Double)

    init {
        var loaded: OrtSession? = null
        try {
            require(metadata.has("max_classified_objects") && roiContext in 0.0..0.5)
            val directory = File(context.filesDir, "models").apply { mkdirs() }
            val file = File(directory, "mango_detector.onnx")
            if (!file.isFile || sha256(file) != modelSha256) {
                val temp = File(directory, "detector.tmp")
                try {
                    context.assets.open("mango_detector.onnx").use { input -> temp.outputStream().use { input.copyTo(it) } }
                    require(sha256(temp) == modelSha256) { "Detector SHA-256 mismatch" }
                    require(temp.renameTo(file)) { "Cannot install detector" }
                } finally { if (temp.exists()) temp.delete() }
            }
            loaded = environment.createSession(file.absolutePath, options)
            require(loaded.inputNames == setOf("image"))
            val input = loaded.inputInfo.getValue("image").info as TensorInfo
            require(input.type == OnnxJavaType.FLOAT && input.shape.contentEquals(inputShape))
            val outputs = loaded.outputInfo.mapValues { (_, node) ->
                node.info as? TensorInfo ?: throw IllegalArgumentException("Invalid detector tensor")
            }
            contract.validateGraph(outputs.mapValues { it.value.shape },
                outputs.filterValues { it.type == OnnxJavaType.FLOAT }.keys,
                outputs.filterValues { it.type == OnnxJavaType.INT64 }.keys)
            val count = outputs.getValue("scores").shape[1].toInt()
            rawBoxes = FloatArray(count * 4)
            rawScores = FloatArray(count)
            rawSpecies = if (contract.speciesAware) LongArray(count) else null
            rawStages = if (stageLabels.isNotEmpty()) LongArray(count) else null
            rawStageScores = if (stageLabels.isNotEmpty()) FloatArray(count * 2) else null
            inputTensor = OnnxTensor.createTensor(environment, tensor, inputShape)
            inputs = mapOf("image" to inputTensor)
            session = loaded; modelBytes = file.length()
        } catch (error: Throwable) {
            loaded?.close(); options.close(); throw error
        }
    }

    fun detect(bitmap: Bitmap): Result {
        val began = SystemClock.elapsedRealtimeNanos()
        val transform = if (contract.rounding == "floor") {
            val scale=minOf(target.toDouble()/bitmap.width,target.toDouble()/bitmap.height)
            val w=maxOf(1,(bitmap.width*scale).toInt());val h=maxOf(1,(bitmap.height*scale).toInt())
            InferenceMath.Letterbox(w,h,if(contract.alignment=="center") (target-w)/2 else 0,
                if(contract.alignment=="center") (target-h)/2 else 0,target)
        } else InferenceMath.letterbox(bitmap.width, bitmap.height, target, contract.alignment)
        val padding = contract.paddingRgb
        val nativePrepared = padding.all { it == 128 } &&
            (nativePreprocessor ?: NativePreprocessor().also { nativePreprocessor = it }).prepare(
                bitmap, tensorMemory, target, transform.scaledWidth, transform.scaledHeight, transform.left, transform.top)
        if (nativePrepared) {
            // Native writes into the direct allocation without changing the FloatBuffer cursor.
            tensor.clear()
        } else {
        if (sourcePixels.size != bitmap.width * bitmap.height) sourcePixels = IntArray(bitmap.width * bitmap.height)
        val source = sourcePixels
        bitmap.getPixels(source, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val scaled = resampler.resizeRgb(source, bitmap.width, bitmap.height, transform.scaledWidth, transform.scaledHeight)
        pixels.fill((0xFF000000.toInt() or (padding[0] shl 16) or (padding[1] shl 8) or padding[2]))
        for (row in 0 until transform.scaledHeight) scaled.copyInto(pixels,
            (row + transform.top) * target + transform.left, row * transform.scaledWidth, (row + 1) * transform.scaledWidth)
        tensor.clear()
        for (i in pixels.indices) {
            val pixel = pixels[i]
            planarPixels[i] = ((pixel ushr 16) and 255) / 255f
            planarPixels[pixels.size + i] = ((pixel ushr 8) and 255) / 255f
            planarPixels[2 * pixels.size + i] = (pixel and 255) / 255f
        }
        tensor.put(planarPixels)
        tensor.flip()
        }
        var modelMs = 0.0
        val raw = rawBoxes; val scores = rawScores
        val speciesIds = rawSpecies; val stageIds = rawStages; val stageScores = rawStageScores
        run {
            val modelStarted = SystemClock.elapsedRealtimeNanos()
            session.run(inputs).use { output ->
                val boxBuffer = (output.get("boxes").get() as OnnxTensor).floatBuffer
                val scoreBuffer = (output.get("scores").get() as OnnxTensor).floatBuffer
                boxBuffer.get(raw)
                scoreBuffer.get(scores)
                if (contract.speciesAware) {
                    val idBuffer = (output.get("species_ids").get() as OnnxTensor).longBuffer
                    idBuffer.get(requireNotNull(speciesIds))
                }
                if (stageLabels.isNotEmpty()) {
                    val ids=(output.get("stage_ids").get() as OnnxTensor).longBuffer
                    ids.get(requireNotNull(stageIds))
                    val values=(output.get("stage_scores").get() as OnnxTensor).floatBuffer
                    values.get(requireNotNull(stageScores))
                }
            }
            modelMs = (SystemClock.elapsedRealtimeNanos() - modelStarted) / 1e6
        }
        val selected = DetectionMath.select(raw, scores, transform, metadata.getDouble("confidence_threshold"),
            metadata.getDouble("nms_iou"), metadata.getInt("max_classified_objects"), speciesIds, contract.nmsMode,
            contract.speciesNames,stageIds,stageScores)
        return Result(selected, modelMs, (SystemClock.elapsedRealtimeNanos() - began) / 1e6)
    }

    override fun close() { nativePreprocessor?.close(); nativePreprocessor = null; inputTensor.close(); session.close(); options.close() }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

/** Explicit detector namespace and serving preprocessing, with legacy defaults. */
internal class DetectorOutputContract private constructor(val speciesAware: Boolean,
    val alignment: String, val paddingRgb: IntArray, val nmsMode: String, val speciesNames: List<String>,
    val stageLabels: List<String>, val rounding: String) {
    fun validateGraph(shapes: Map<String, LongArray>, floats: Set<String>, int64s: Set<String>) {
        val direct=stageLabels.isNotEmpty()
        val names = if (direct) setOf("boxes","scores","species_ids","stage_ids","stage_scores")
            else if (speciesAware) setOf("boxes", "scores", "species_ids") else setOf("boxes", "scores")
        val boxes = shapes["boxes"] ?: throw IllegalArgumentException("Missing detector boxes")
        val scores = shapes["scores"] ?: throw IllegalArgumentException("Missing detector scores")
        require(shapes.keys == names && floats == (if(direct) setOf("boxes","scores","stage_scores") else setOf("boxes", "scores")) &&
            int64s == (if(direct) setOf("species_ids","stage_ids") else if (speciesAware) setOf("species_ids") else emptySet<String>())) { "Invalid detector output types" }
        require(boxes.size == 3 && scores.size == 2 && boxes[0] == 1L && boxes[2] == 4L &&
            scores[0] == 1L && boxes[1] == scores[1] && scores[1] > 0) { "Invalid detector output shapes" }
        if (speciesAware) require(shapes.getValue("species_ids").contentEquals(scores)) { "Invalid detector species shape" }
        if(direct) require(shapes.getValue("stage_ids").contentEquals(scores) &&
            shapes.getValue("stage_scores").contentEquals(longArrayOf(1,scores[1],2))) { "Invalid direct stage shapes" }
    }

    companion object {
        val allowedSpeciesNames = setOf("mango", "apple", "guava", "papaya", "banana", "orange", "fruit")
        fun fromMetadata(metadata: Map<String, Any?>): DetectorOutputContract {
            val aware = metadata.containsKey("species_names")
            val speciesNames = if (aware) {
                val names = metadata["species_names"] as? List<*>
                    ?: throw IllegalArgumentException("Invalid detector species namespace")
                require(names.size in 1..allowedSpeciesNames.size && names.distinct().size == names.size &&
                    names.all { it is String && it in allowedSpeciesNames }) { "Invalid detector species namespace" }
                names.map { it as String }
            } else listOf("mango")
            val nmsMode = if (metadata.containsKey("nms_mode")) metadata["nms_mode"] as? String
                ?: throw IllegalArgumentException("Invalid detector NMS mode") else "class_aware"
            require(nmsMode in setOf("class_aware", "class_agnostic")) { "Invalid detector NMS mode" }
            require(metadata.containsKey("letterbox_alignment") == metadata.containsKey("padding_rgb")) {
                "Detector preprocessing must declare alignment and padding together"
            }
            val alignment = if (metadata.containsKey("letterbox_alignment")) metadata["letterbox_alignment"] as? String
                ?: throw IllegalArgumentException("Invalid detector letterbox alignment") else "center"
            require(alignment in setOf("center", "top_left")) { "Invalid detector letterbox alignment" }
            val padding = if (metadata.containsKey("padding_rgb")) {
                val values = metadata["padding_rgb"] as? List<*> ?: throw IllegalArgumentException("Invalid detector padding")
                require(values.size == 3 && values.all { it is Number && it.toDouble().isFinite() &&
                    it.toDouble() in 0.0..255.0 && it.toDouble() == it.toInt().toDouble() }) { "Invalid detector padding" }
                IntArray(3) { (values[it] as Number).toInt() }
            } else intArrayOf(128, 128, 128)
            val stages=if(metadata.containsKey("stage_labels")) {
                require(aware && metadata["stage_labels"] == listOf("Xanh / chưa chín","Chín")) { "Unknown source stages" }
                listOf("Xanh / chưa chín","Chín")
            } else emptyList()
            if ("fruit" in speciesNames) require(stages.isNotEmpty() &&
                metadata["geometry_only_grade_abstention"] == true) {
                "Generic fruit must explicitly abstain from source grades"
            }
            if(metadata.containsKey("max_classified_objects")) {
                val limit=metadata["max_classified_objects"] as? Number
                    ?: throw IllegalArgumentException("Invalid detector object budget")
                require(limit.toDouble().isFinite() && limit.toDouble()==limit.toInt().toDouble() &&
                    limit.toInt() in 1..(if(stages.isEmpty()) 8 else 64)) { "Invalid detector object budget" }
            }
            val rounding=metadata["letterbox_rounding"] as? String ?: "nearest"
            require(rounding in setOf("floor","nearest")) { "Invalid resize rounding" }
            return DetectorOutputContract(aware, alignment, padding, nmsMode, speciesNames,stages,rounding)
        }
    }
}
