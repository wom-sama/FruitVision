package vn.mangodemo.mango_offline

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/** Camera preview only. Each JPEG is requested by Dart after the previous API response.
 * There is no model, continuous encoding loop, disk frame cache or unbounded queue.
 */
class LiveCameraPlatform(private val activity:MainActivity, engine:FlutterEngine):DefaultLifecycleObserver {
    private val views=mutableMapOf<Int,CameraView>()
    private val channel=MethodChannel(engine.dartExecutor.binaryMessenger,"vn.fruitvision/live_camera")
    private var permission:Pair<Int,MethodChannel.Result>?=null
    private val permissionCode=4611
    init {
        activity.lifecycle.addObserver(this)
        engine.platformViewsController.registry.registerViewFactory("vn.fruitvision/live_camera/preview",
            object:PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context:Context,id:Int,args:Any?):PlatformView = CameraView(id).also { views[id]=it }
            })
        channel.setMethodCallHandler { call,result ->
            val id=call.argument<Int>("viewId")
            val view=views[id]
            if(view==null) { result.error("CAMERA_VIEW","Khung camera chưa sẵn sàng.",null); return@setMethodCallHandler }
            when(call.method) {
                "start" -> {
                    if(ContextCompat.checkSelfPermission(activity,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) view.start(result)
                    else if(permission!=null) result.error("CAMERA_BUSY","Đang chờ cấp quyền camera.",null)
                    else { permission=id!! to result; activity.requestPermissions(arrayOf(Manifest.permission.CAMERA),permissionCode) }
                }
                "frame" -> view.frame(result)
                "stop" -> { view.stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    fun onPermissionResult(code:Int) {
        if(code!=permissionCode)return
        val pending=permission ?: return; permission=null
        val view=views[pending.first]
        if(view!=null && ContextCompat.checkSelfPermission(activity,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) view.start(pending.second)
        else pending.second.error("CAMERA_PERMISSION","Cần quyền camera để nhận diện trực tiếp.",null)
    }
    override fun onPause(owner:LifecycleOwner) { views.values.toList().forEach { it.stop() } }
    fun close() {
        channel.setMethodCallHandler(null)
        permission?.second?.error("CAMERA_CLOSED","Đã đóng camera.",null); permission=null
        views.values.toList().forEach { it.dispose() }; views.clear()
        activity.lifecycle.removeObserver(this)
    }
    private inner class CameraView(private val id:Int):PlatformView {
        private val previewView=PreviewView(activity).apply {
            implementationMode=PreviewView.ImplementationMode.COMPATIBLE
            scaleType=PreviewView.ScaleType.FILL_CENTER
        }
        private val encoder=Executors.newSingleThreadExecutor()
        private val main=Handler(Looper.getMainLooper())
        private var provider:ProcessCameraProvider?=null
        private var preview:Preview?=null
        private var generation=0
        private var disposed=false
        private var busy=false
        private var starting:MethodChannel.Result?=null
        private var running=false
        override fun getView():View=previewView
        fun start(result:MethodChannel.Result) {
            if(disposed) { result.error("CAMERA_CLOSED","Đã đóng camera.",null);return }
            if(running) { result.success(null);return }
            if(starting!=null) { result.error("CAMERA_BUSY","Camera đang khởi động.",null);return }
            val ticket=++generation; starting=result
            val future=ProcessCameraProvider.getInstance(activity)
            future.addListener({
                if(ticket!=generation || disposed)return@addListener
                try {
                    val cameraProvider=future.get()
                    require(cameraProvider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA))
                    val useCase=Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                    cameraProvider.bindToLifecycle(activity,CameraSelector.DEFAULT_BACK_CAMERA,useCase)
                    provider=cameraProvider;preview=useCase;running=true
                    starting=null;result.success(null)
                } catch(_:Exception) { starting=null;result.error("CAMERA_START","Không mở được camera sau. Hãy đóng ứng dụng camera khác rồi thử lại.",null) }
            },ContextCompat.getMainExecutor(activity))
            main.postDelayed({
                if(ticket==generation && starting!=null) { generation++;starting=null;result.error("CAMERA_TIMEOUT","Camera chưa sẵn sàng. Hãy thử lại.",null) }
            },10_000)
        }
        fun frame(result:MethodChannel.Result) {
            if(!running || disposed) { result.error("CAMERA_STOPPED","Camera đã dừng.",null);return }
            if(busy) { result.error("CAMERA_BUSY","Đang chuẩn bị một khung hình.",null);return }
            // getBitmap is main-thread only; it has the same crop/rotation as the visible preview.
            val bitmap=previewView.bitmap
            if(bitmap==null) { result.error("CAMERA_NOT_READY","Đang chờ hình ảnh từ camera.",null);return }
            busy=true; val ticket=generation
            encoder.execute {
                var scaled:Bitmap?=null
                try {
                    val (width,height)=LiveFrameGeometry.size(bitmap.width,bitmap.height)
                    scaled=if(width==bitmap.width && height==bitmap.height)bitmap else Bitmap.createScaledBitmap(bitmap,width,height,true)
                    val output=ByteArrayOutputStream()
                    check(scaled.compress(Bitmap.CompressFormat.JPEG,72,output))
                    val bytes=output.toByteArray();require(bytes.size in 1..1048576)
                    main.post {
                        busy=false
                        if(ticket!=generation || disposed || !running) result.error("CAMERA_STALE","Khung hình đã hết hiệu lực.",null)
                        else result.success(mapOf("bytes" to bytes,"width" to width,"height" to height))
                    }
                } catch(_:Exception) { main.post { busy=false;result.error("CAMERA_FRAME","Không chuẩn bị được khung hình camera.",null) } }
                finally { if(scaled!==bitmap)scaled?.recycle();bitmap.recycle() }
            }
        }
        fun stop() {
            generation++;running=false
            starting?.error("CAMERA_STOPPED","Camera đã dừng.",null);starting=null
            preview?.let { provider?.unbind(it) };preview=null;provider=null
        }
        override fun dispose() {
            if(disposed)return
            stop();disposed=true;views.remove(id)
            if(permission?.first==id) { permission?.second?.error("CAMERA_CLOSED","Đã đóng camera.",null);permission=null }
            // Let the sole current encode recycle its Bitmap; never kill another camera owner.
            encoder.shutdown()
        }
    }
}

internal object LiveFrameGeometry {
    fun size(width:Int,height:Int):Pair<Int,Int> {
        require(width>0 && height>0)
        val ratio=minOf(1.0,960.0/max(width,height))
        return max(1,(width*ratio).roundToInt()) to max(1,(height*ratio).roundToInt())
    }
}
