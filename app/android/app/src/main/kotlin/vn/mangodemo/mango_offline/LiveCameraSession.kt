package vn.mangodemo.mango_offline

import android.content.Context
import android.graphics.RectF
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Size
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.transform.CoordinateTransform
import androidx.camera.view.transform.ImageProxyTransformFactory
import androidx.camera.view.transform.OutputTransform
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Main-thread camera lifecycle; all conversion/ORT on the shared, activity-owned worker. */
class LiveCameraSession(
    private val context: Context, private val owner: LifecycleOwner,
    private val worker: ExecutorService, private val engine: () -> NativeInferenceEngine,
    private val releaseEngine: () -> Unit, private val emit: (Map<String, Any>) -> Unit,
) : DefaultLifecycleObserver {
    private val main = Handler(Looper.getMainLooper())
    @Volatile var active = false; private set
    @Volatile private var generation = 0
    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null
    private var previewUseCase: Preview? = null
    private var view: LivePreviewView? = null
    private var ready: ((Throwable?) -> Unit)? = null
    private var layoutListener: View.OnLayoutChangeListener? = null
    private var lens = "back"
    private var requestedFps = 5
    private var policy = LiveFramePolicy(5)
    private val lock = Any()
    private var startedNs = 0L
    private var stoppedNs = 0L
    private var processed = 0L
    private var pss = 0.0
    private var nextPssNs = 0L
    private var thermalStatus = 0
    private var effectiveFps = 5
    private var imageWidth = 0
    private var imageHeight = 0
    private var model = LiveSamples()
    private var pipeline = LiveSamples()
    private var conversion = LiveSamples()
    private var callbackAge = LiveSamples()
    private val pending = AtomicReference<FrameResult?>()
    private val posted = AtomicBoolean(false)
    private val overlayIdentity = LiveOverlayIdentity()
    private var displayedBoxes = emptyList<LivePreviewView.Box>()
    private var displayedObjects = emptyList<Map<*, *>>()
    private fun clearIdentity() {
        overlayIdentity.clear(); displayedBoxes = emptyList(); displayedObjects = emptyList()
    }
    private val rebind = Runnable {
        if (active && view != null) {
            generation++; pending.set(null); view?.clearBox(); clearIdentity()
            analysis?.clearAnalyzer()
            provider?.unbind(*listOfNotNull(analysis, previewUseCase).toTypedArray())
            analysis = null; previewUseCase = null
            try { bind(generation) } catch (error: Exception) { fail(error) }
        }
    }
    private data class FrameResult(val generation: Int, val callbackNs: Long, val result: Map<String, Any>,
        val boxes: List<LivePreviewView.Box>, val transform: OutputTransform)

    init { owner.lifecycle.addObserver(this) }

    fun start(target: LivePreviewView, lensFacing: String, maxFps: Int, onReady: (Throwable?) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (active) { onReady(IllegalStateException("Camera already running")); return }
        require(lensFacing in setOf("back", "front")); require(maxFps in 1..30)
        active = true; generation++; val token = generation
        clearIdentity()
        view = target; lens = lensFacing; requestedFps = maxFps; ready = onReady
        synchronized(lock) {
            startedNs = SystemClock.elapsedRealtimeNanos(); stoppedNs = 0
            policy = LiveFramePolicy(maxFps); effectiveFps = maxFps; thermalStatus = 0
            processed = 0; pss = 0.0; nextPssNs = 0
            imageWidth = 0; imageHeight = 0
            model = LiveSamples(); pipeline = LiveSamples(); conversion = LiveSamples(); callbackAge = LiveSamples()
        }
        emit(mapOf("type" to "state", "state" to "starting"))
        worker.execute {
            try {
                if (active && generation == token) engine().prepare(multiObject = true)
                main.post {
                    if (!active || generation != token) return@post
                    val future = ProcessCameraProvider.getInstance(context)
                    future.addListener({
                        if (!active || generation != token) return@addListener
                        try {
                            provider = future.get()
                            if (target.width > 0 && target.height > 0) bind(token)
                            else {
                                layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                                    if (active && generation == token && target.width > 0 && target.height > 0) {
                                        target.removeOnLayoutChangeListener(layoutListener); layoutListener = null
                                        try { bind(token) } catch (error: Exception) { fail(error) }
                                    }
                                }
                                target.addOnLayoutChangeListener(layoutListener)
                            }
                        } catch (error: Exception) { fail(error) }
                    }, ContextCompat.getMainExecutor(context))
                }
            } catch (error: Exception) { main.post { if (generation == token) fail(error) } }
            catch (error: OutOfMemoryError) { main.post { if (generation == token) fail(IllegalStateException("Not enough memory for live camera", error)) } }
        }
        // Finite startup timeout, including unavailable/failed camera acquisition.
        main.postDelayed({ if (active && generation == token && ready != null) fail(IllegalStateException("Camera startup timed out")) }, 15_000)
    }

    private fun bind(token: Int) {
        val target = view ?: return
        val cameraProvider = provider ?: return
        val selector = if (lens == "front") CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        require(cameraProvider.hasCamera(selector)) { "${lens} camera is not available on this device" }
        val rotation = target.display?.rotation ?: android.view.Surface.ROTATION_0
        val preview = Preview.Builder().setTargetRotation(rotation).build()
        val analyzer = ImageAnalysis.Builder().setTargetRotation(rotation)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(
                ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)).build())
            .build()
        preview.setSurfaceProvider(target.preview.surfaceProvider)
        val viewport = requireNotNull(target.preview.viewPort) { "Preview has no laid-out viewport" }
        val group = UseCaseGroup.Builder().setViewPort(viewport).addUseCase(preview).addUseCase(analyzer).build()
        analyzer.setAnalyzer(worker) { proxy -> analyze(proxy, token) }
        previewUseCase = preview; analysis = analyzer
        cameraProvider.bindToLifecycle(owner, selector, group)
        if (layoutListener == null) {
            layoutListener = View.OnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
                if (active && (right-left != oldRight-oldLeft || bottom-top != oldBottom-oldTop)) {
                    // Viewport shape/rotation changed: invalidate old geometry before rebinding.
                    generation++; pending.set(null); target.clearBox(); clearIdentity()
                    main.removeCallbacks(rebind); main.postDelayed(rebind, 200)
                }
            }
            target.addOnLayoutChangeListener(layoutListener)
        }
        // First actual analyzed frame signals ready; binding alone is not evidence of a stream.
    }

    private fun analyze(image: ImageProxy, token: Int) {
        val callbackNs = SystemClock.elapsedRealtimeNanos()
        try {
            if (!active || generation != token) return
            val admitted = synchronized(lock) { policy.accept(callbackNs) }
            if (!admitted) return
            val transform = ImageProxyTransformFactory().getOutputTransform(image) // original buffer coordinates
            CameraFrame.fromProxy(image).use { frame ->
                val conversionMs = (SystemClock.elapsedRealtimeNanos() - callbackNs) / 1e6
                val result = engine().analyzeCameraBitmap(frame.bitmap, callbackNs, multiObject = true)
                if (!active || generation != token) return
                val boxes = (result["objects"] as List<*>).mapIndexed { index, item ->
                    val objectResult = item as Map<*, *>
                    val coordinates = (objectResult["box"] as List<*>).map { (it as Number).toDouble() }.toDoubleArray()
                    val presentation = LiveObjectPresentation.fromResult(index, objectResult, trackId = null)
                    LivePreviewView.Box(frame.toBufferBox(coordinates), presentation.label, presentation.classId)
                }
                synchronized(lock) {
                    processed++; imageWidth = frame.bitmap.width; imageHeight = frame.bitmap.height
                    if (processed > 5) {
                        conversion.add(conversionMs); model.add(result["modelMs"] as Double)
                        pipeline.add(result["elapsedMs"] as Double)
                    }
                    if (callbackNs >= nextPssNs) {
                        pss = Debug.getPss() / 1024.0; nextPssNs = callbackNs + 3_000_000_000L
                        if (android.os.Build.VERSION.SDK_INT >= 29) {
                            thermalStatus = (context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus
                            effectiveFps = LiveFramePolicy.thermalFps(requestedFps, thermalStatus)
                            policy.setMaxFps(effectiveFps)
                        }
                    }
                }
                if (thermalStatus >= 4) { main.post { if (active && generation == token) fail(IllegalStateException("Device too hot; let it cool before restarting camera")) }; return }
                pending.set(FrameResult(token, callbackNs, result, boxes, transform)); postLatest()
            }
        } catch (error: Exception) { main.post { if (active && generation == token) fail(error) } }
        catch (error: OutOfMemoryError) { main.post { if (active && generation == token) fail(IllegalStateException("Live camera ran out of memory", error)) } }
        finally { image.close() }
    }

    private fun postLatest() {
        if (!posted.compareAndSet(false, true)) return
        main.post {
            try {
                val frame = pending.getAndSet(null)
                val target = view
                if (frame != null && target != null && active && generation == frame.generation) {
                    val ageMs = (SystemClock.elapsedRealtimeNanos() - frame.callbackNs) / 1e6
                    val output = target.preview.outputTransform
                    if (output != null && ageMs < 1000) {
                        val transform = CoordinateTransform(frame.transform, output)
                        displayedBoxes = frame.boxes.map { box ->
                            val mapped = RectF(box.rect); transform.mapRect(mapped)
                            box.copy(rect = mapped)
                        }
                        displayedObjects = (frame.result["objects"] as List<*>).map { it as Map<*, *> }
                        overlayIdentity.frame(frame.callbackNs / 1_000_000L, displayedBoxes.size)
                        target.showBoxes(displayedBoxes)
                    } else { target.clearBox(); clearIdentity() }
                    synchronized(lock) { if (processed > 5) callbackAge.add(ageMs) }
                    ready?.also { ready = null; it(null); emit(mapOf("type" to "state", "state" to "running")) }
                    emit(frame.result + mapOf("type" to "frame", "stats" to stats(), "timestampMs" to frame.callbackNs / 1_000_000L))
                }
            } catch (error: Exception) { fail(error) }
            finally { posted.set(false); if (pending.get() != null) postLatest() }
        }
    }

    fun stats(): Map<String, Any> = synchronized(lock) {
        val now = if (stoppedNs > 0) stoppedNs else SystemClock.elapsedRealtimeNanos()
        val seconds = if (startedNs == 0L) 0.0 else (now - startedNs) / 1e9
        mapOf("processed" to processed, "skipped" to policy.skipped, "delivered" to policy.delivered,
            "inferenceFps" to if (seconds > 0) processed / seconds else 0.0,
            "analyzerFps" to if (seconds > 0) policy.delivered / seconds else 0.0,
            "maxFps" to requestedFps, "effectiveMaxFps" to effectiveFps, "thermalStatus" to thermalStatus,
            "modelP50Ms" to model.percentile(.5), "modelP95Ms" to model.percentile(.95),
            "pipelineP50Ms" to pipeline.percentile(.5), "pipelineP95Ms" to pipeline.percentile(.95),
            "conversionP95Ms" to conversion.percentile(.95), "callbackToOverlayP95Ms" to callbackAge.percentile(.95),
            "pssMb" to pss, "uptimeMs" to seconds * 1000, "sampleCount" to model.count,
            "analysisWidth" to imageWidth, "analysisHeight" to imageHeight)
    }

    fun annotate(timestampMs: Long, ids: List<Int>) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (!active || !overlayIdentity.accepts(timestampMs, ids)) return
        view?.showBoxes(displayedBoxes.mapIndexed { index, box ->
            val presentation = LiveObjectPresentation.fromResult(index, displayedObjects[index], ids[index])
            box.copy(label = presentation.label, classId = presentation.classId)
        })
    }

    fun stop(onStopped: () -> Unit = {}) {
        check(Looper.myLooper() == Looper.getMainLooper())
        active = false; generation++; pending.set(null); clearIdentity()
        main.removeCallbacks(rebind)
        synchronized(lock) { if (startedNs > 0 && stoppedNs == 0L) stoppedNs = SystemClock.elapsedRealtimeNanos() }
        ready?.also { ready = null; it(IllegalStateException("Camera startup cancelled")) }
        view?.let { target -> layoutListener?.let { target.removeOnLayoutChangeListener(it) }; target.clearBox() }
        layoutListener = null
        analysis?.clearAnalyzer()
        val owned = listOfNotNull(analysis, previewUseCase).toTypedArray()
        if (owned.isNotEmpty()) provider?.unbind(*owned)
        analysis = null; previewUseCase = null
        emit(mapOf("type" to "state", "state" to "stopped"))
        // Barrier after in-flight ORT and already-posted results; no stale event after stop reply.
        worker.execute { releaseEngine(); main.post { onStopped() } }
    }
    private fun fail(error: Throwable) {
        val callback = ready; ready = null
        // Publish cause before stopped; otherwise a client cancels its event subscription
        // on stopped and never sees the following error.
        emit(mapOf("type" to "state", "state" to "error", "message" to (error.message ?: error.javaClass.simpleName)))
        stop()
        callback?.invoke(error)
    }
    override fun onStop(owner: LifecycleOwner) { if (active) stop() }
    override fun onDestroy(owner: LifecycleOwner) { owner.lifecycle.removeObserver(this) }
}
