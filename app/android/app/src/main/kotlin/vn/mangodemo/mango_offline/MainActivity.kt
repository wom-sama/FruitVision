package vn.mangodemo.mango_offline

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private val destroyed = AtomicBoolean(false)
    private var engine: NativeInferenceEngine? = null
    private lateinit var live: LiveCameraSession
    private val previews = mutableMapOf<Int, LivePreviewView>()
    private var cameraSink: EventChannel.EventSink? = null
    private var permissionReply: MethodChannel.Result? = null
    private var permittedStart: (() -> Unit)? = null
    private var liveViewId: Int? = null

    private fun currentEngine(): NativeInferenceEngine = engine ?: NativeInferenceEngine(applicationContext).also { engine = it }
    private fun releaseEngine() { engine?.close(); engine = null }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        live = LiveCameraSession(this, this, worker, ::currentEngine, ::releaseEngine) { event ->
            if (!destroyed.get()) cameraSink?.success(event)
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.mangodemo/live_camera/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) { cameraSink = events }
                override fun onCancel(arguments: Any?) { cameraSink = null }
            })
        flutterEngine.platformViewsController.registry.registerViewFactory("vn.mangodemo/live_preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val preview = LivePreviewView(this@MainActivity)
                    previews[viewId] = preview
                    return object : PlatformView {
                        override fun getView() = preview
                        override fun dispose() {
                            if (!destroyed.get() && liveViewId == viewId) { cancelCameraPermission(); live.stop(); liveViewId = null }
                            previews.remove(viewId)
                        }
                    }
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.mangodemo/live_camera").setMethodCallHandler { call, reply ->
            if (destroyed.get()) { reply.error("CLOSED", "Activity closed", null); return@setMethodCallHandler }
            when (call.method) {
                "annotate" -> {
                    val timestamp = call.argument<Number>("timestampMs")?.toLong()
                    val ids = call.argument<List<Int>>("trackIds")
                    if (timestamp == null || timestamp < 0 || ids == null) reply.error("ARGUMENT", "Invalid overlay identity", null)
                    else try { live.annotate(timestamp, ids); reply.success(null) }
                    catch (error: IllegalArgumentException) { reply.error("ARGUMENT", error.message, null) }
                }
                "stats" -> reply.success(live.stats())
                "stop" -> { cancelCameraPermission(); live.stop { reply.success(null) }; liveViewId = null }
                "start" -> {
                    val viewId = call.argument<Int>("viewId")
                    val target = previews[viewId]
                    val lens = call.argument<String>("lensFacing") ?: "back"
                    val fps = call.argument<Int>("maxFps") ?: 30
                    if (target == null || lens !in setOf("back", "front") || fps !in 1..30) {
                        reply.error("ARGUMENT", "Invalid preview, lens or rate", null)
                    } else if (busy.get() || live.active || permissionReply != null || engine?.videoSequenceOpen==true) {
                        reply.error("BUSY", "Another analysis or camera is active", null)
                    } else {
                        val start = {
                            if (!destroyed.get() && !busy.get() && previews[viewId] === target) {
                                liveViewId = viewId
                                live.start(target, lens, fps) { error ->
                                    if (error == null) reply.success(mapOf("started" to true))
                                    else reply.error("CAMERA", error.message ?: "Camera failed", null)
                                }
                            } else reply.error("CANCELLED", "Preview closed or analysis busy", null)
                        }
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) start()
                        else {
                            permissionReply = reply; permittedStart = start
                            requestPermissions(arrayOf(Manifest.permission.CAMERA), 401)
                        }
                    }
                }
                else -> reply.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.mangodemo/inference")
            .setMethodCallHandler { call, reply ->
                if (destroyed.get()) { reply.error("CLOSED", "Activity closed", null); return@setMethodCallHandler }
                if (call.method == "close") {
                    if (live.active) live.stop { reply.success(null) }
                    else worker.execute { releaseEngine(); main.post { if (!destroyed.get()) reply.success(null) } }
                    return@setMethodCallHandler
                }
                if (call.method !in setOf("prepare", "analyzeImage", "videoInfo", "analyzeVideoFrame",
                        "openVideoSequence", "nextVideoFrame", "closeVideoSequence")) {
                    reply.notImplemented(); return@setMethodCallHandler
                }
                if (live.active || permissionReply != null || !busy.compareAndSet(false, true)) { reply.error("BUSY", "One analysis or live camera is already running", null); return@setMethodCallHandler }
                worker.execute {
                    try {
                        val current = currentEngine()
                        val result = when (call.method) {
                            "prepare" -> current.prepare(multiObject = true)
                            "videoInfo" -> current.videoInfo(requireNotNull(call.argument<String>("path")))
                            "analyzeVideoFrame" -> current.analyzeVideoFrame(requireNotNull(call.argument<String>("path")), requireNotNull(call.argument<Number>("timeMs")).toLong(), multiObject = true)
                            "openVideoSequence" -> current.openVideoSequence(requireNotNull(call.argument<String>("path")))
                            "nextVideoFrame" -> current.nextVideoFrame(requireNotNull(call.argument<String>("path")), multiObject = true)
                            "closeVideoSequence" -> { current.closeVideoSequence(); null }
                            else -> current.analyzeImage(requireNotNull(call.argument<String>("path")), multiObject = true)
                        }
                        main.post {
                            // Release on the reply thread before Dart can submit
                            // its next sequential video frame.
                            busy.set(false)
                            if (!destroyed.get()) reply.success(result)
                        }
                    } catch (error: OutOfMemoryError) {
                        engine?.close(); engine = null
                        main.post {
                            busy.set(false)
                            if (!destroyed.get()) reply.error("LOW_MEMORY", "Not enough memory; choose a smaller image or video", null)
                        }
                    } catch (error: Exception) {
                        main.post {
                            busy.set(false)
                            if (!destroyed.get()) reply.error("INFERENCE", error.message ?: error.javaClass.simpleName, null)
                        }
                    }
                }
            }
    }

    private fun cancelCameraPermission() {
        permissionReply?.error("CANCELLED", "Camera start cancelled", null)
        permissionReply = null; permittedStart = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 401) return
        val reply = permissionReply; val start = permittedStart
        permissionReply = null; permittedStart = null
        if (reply == null) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && !destroyed.get()) start?.invoke()
        else reply.error("PERMISSION", "Camera permission denied. Allow Camera in Android app settings, then retry.", null)
    }

    override fun onDestroy() {
        cancelCameraPermission()
        if (::live.isInitialized) live.stop()
        destroyed.set(true)
        liveViewId = null; previews.clear(); cameraSink = null
        worker.execute { releaseEngine() }
        worker.shutdown()
        super.onDestroy()
    }
}
