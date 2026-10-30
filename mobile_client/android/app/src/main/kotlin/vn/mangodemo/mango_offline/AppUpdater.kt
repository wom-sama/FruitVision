package vn.mangodemo.mango_offline

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection

/** One bounded streaming download, scoped cache and explicit Android installation UI. */
internal class AppUpdater(private val activity: Activity, private val channel: MethodChannel) {
    private val executor = Executors.newSingleThreadExecutor()
    private val active = AtomicReference<AtomicBoolean?>(null)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var closed = false
    private val directory by lazy { File(activity.cacheDir, "fv_updates").apply { mkdirs() }.canonicalFile }
    @Suppress("DEPRECATION")
    private val flags get() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun installed() = activity.packageManager.getPackageInfo(activity.packageName, flags)
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo) = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val values = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return values?.map { digest(it.toByteArray()) }?.toSet() ?: emptySet()
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun onUi(block: () -> Unit) { activity.runOnUiThread { if (!closed) block() } }
    private fun number(call: MethodCall, name: String) = (call.argument<Number>(name) ?: error("Missing $name")).toLong()
    private fun text(call: MethodCall, name: String) = call.argument<String>(name) ?: error("Missing $name")
    private fun ownedFile(path: String): File = File(path).canonicalFile.also {
        require(it.parentFile == directory && it.name.matches(Regex("update_[a-zA-Z0-9_-]+\\.apk")) && it.isFile)
    }
    private fun archive(file: File, expectedSha: String, expectedSize: Long, expectedVersion: Long): PackageInfo {
        require(expectedSize in 1..UpdatePolicy.MAX_BYTES && expectedSha.matches(Regex("[a-fA-F0-9]{64}")))
        require(file.length() == expectedSize)
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; sha.update(buffer, 0, count) }
        }
        require(sha.digest().joinToString("") { "%02x".format(it) }.equals(expectedSha, ignoreCase=true))
        @Suppress("DEPRECATION")
        val candidate = activity.packageManager.getPackageArchiveInfo(file.absolutePath, flags) ?: error("Invalid APK")
        val current = installed()
        UpdatePolicy.archive(candidate.packageName, activity.packageName, version(candidate), expectedVersion,
            version(current), signers(candidate), signers(current),
            ((candidate.applicationInfo?.flags ?: error("Missing app")) and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
        return candidate
    }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> {
                    val current = installed()
                    result.success(mapOf("packageName" to activity.packageName, "versionName" to current.versionName,
                        "versionCode" to version(current), "abis" to Build.SUPPORTED_ABIS.toList(),
                        "canRequestInstalls" to activity.packageManager.canRequestPackageInstalls()))
                }
                "cancel" -> { active.get()?.set(true); connection?.disconnect(); result.success(null) }
                "requestPermission" -> {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "download" -> download(call, result)
                "cached" -> {
                    val sha=text(call,"sha256"); val size=number(call,"sizeBytes"); val code=number(call,"versionCode")
                    require(sha.matches(Regex("[a-fA-F0-9]{64}")) && size in 1..UpdatePolicy.MAX_BYTES && code>version(installed()))
                    executor.execute {
                        try {
                            // Permission changes and memory pressure can kill the process. Recover only
                            // already complete APKs, revalidated against the current server descriptor.
                            val files=directory.listFiles()?.filter {
                                it.isFile && it.parentFile?.canonicalFile==directory &&
                                    it.name.matches(Regex("update_[a-zA-Z0-9_-]+\\.apk")) && it.length()==size
                            }?.sortedByDescending { it.lastModified() }?.take(3) ?: emptyList()
                            var found: Map<String,Any?>?=null
                            for (file in files) {
                                if(closed || Thread.currentThread().isInterrupted) break
                                try {
                                    val info=archive(ownedFile(file.absolutePath),sha,size,code)
                                    found=mapOf("path" to file.absolutePath,"versionName" to info.versionName,
                                        "versionCode" to version(info),"sizeBytes" to size)
                                    break
                                } catch (_: Exception) { /* A different or invalid cached release is not a candidate. */ }
                            }
                            val payload=found
                            onUi { result.success(payload) }
                        } catch (_: Exception) { onUi { result.error("UPDATE_CACHE","Không kiểm tra được gói cập nhật tạm.",null) } }
                    }
                }
                "install" -> {
                    val path = text(call,"path"); val sha=text(call,"sha256")
                    val size=number(call,"sizeBytes"); val code=number(call,"versionCode")
                    executor.execute {
                        try {
                            val file=ownedFile(path); archive(file,sha,size,code)
                            onUi {
                                if (!activity.packageManager.canRequestPackageInstalls()) {
                                    result.error("UPDATE_PERMISSION","Cho phép FruitVision yêu cầu cài bản cập nhật trong Cài đặt Android.",null)
                                } else try {
                                    val uri=FileProvider.getUriForFile(activity,"${activity.packageName}.media",file)
                                    activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri,"application/vnd.android.package-archive")
                                        clipData=ClipData.newRawUri("FruitVision update",uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    })
                                    result.success(mapOf("started" to true))
                                } catch (_: Exception) { result.error("UPDATE_INSTALL","Không mở được trình cài đặt Android.",null) }
                            }
                        } catch (_: Exception) { onUi { result.error("UPDATE_INVALID","Gói cập nhật không khớp phiên bản, chữ ký hoặc mã kiểm tra.",null) } }
                    }
                }
                "delete" -> {
                    val path=text(call,"path")
                    executor.execute {
                        try { val file=ownedFile(path); check(file.delete()); onUi { result.success(null) } }
                        catch (_: Exception) { onUi { result.error("UPDATE_DELETE","Không xóa được gói cập nhật tạm.",null) } }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("UPDATE_REQUEST","Yêu cầu cập nhật không hợp lệ.",null) }
    }
    private fun download(call: MethodCall, result: MethodChannel.Result) {
        val base=text(call,"baseUrl"); val path=text(call,"downloadPath"); val sha=text(call,"sha256")
        val size=number(call,"sizeBytes"); val code=number(call,"versionCode")
        val uri=UpdatePolicy.downloadUri(base,path,sha,size,code,version(installed()))
        val cancel=AtomicBoolean(false)
        if (!active.compareAndSet(null,cancel)) { result.error("UPDATE_BUSY","Đang tải một bản cập nhật.",null); return }
        val started=System.nanoTime()
        val expired=AtomicBoolean(false)
        val deadline=Runnable { if(active.get()===cancel) { expired.set(true); connection?.disconnect() } }
        mainHandler.postDelayed(deadline,180000)
        fun checkTransfer() { check(!cancel.get() && !expired.get() && System.nanoTime()-started<180000000000L) }
        executor.execute {
            var partial: File?=null; var finished: File?=null
            try {
                // Only our abandoned copies, never media, sessions or another application's files.
                val cutoff=System.currentTimeMillis()-24*60*60*1000
                directory.listFiles()?.filter { it.isFile && it.lastModified()<cutoff }?.forEach { it.delete() }
                val local=File.createTempFile("update_", ".part", directory); partial=local
                val http=uri.toURL().openConnection() as HttpsURLConnection; connection=http
                http.instanceFollowRedirects=false; http.connectTimeout=15000; http.readTimeout=20000
                http.setRequestProperty("Accept-Encoding","identity")
                require(http.responseCode == 200)
                val advertised=http.contentLengthLong
                require(advertised == -1L || advertised == size)
                var total=0L; var lastProgress=0L
                http.inputStream.use { input -> local.outputStream().use { output ->
                    val buffer=ByteArray(64*1024)
                    while (true) {
                        checkTransfer(); check(!Thread.currentThread().isInterrupted)
                        val count=input.read(buffer); if(count<0)break
                        total+=count; require(total<=size); output.write(buffer,0,count)
                        val now=System.nanoTime()
                        if(now-lastProgress>=250000000L || total==size) {
                            lastProgress=now
                            val progress=total
                            onUi { channel.invokeMethod("progress",mapOf("downloaded" to progress,"total" to size)) }
                        }
                    }
                } }
                checkTransfer(); require(total==size)
                val candidate=archive(local,sha,size,code)
                checkTransfer()
                val file=File(directory,local.nameWithoutExtension+".apk")
                check(local.renameTo(file)); partial=null; finished=file
                activity.runOnUiThread {
                    active.compareAndSet(cancel,null)
                    if (closed || cancel.get() || expired.get()) {
                        file.delete()
                        if(!closed) result.error("UPDATE_CANCELLED","Đã hủy tải cập nhật.",null)
                    } else result.success(mapOf("path" to file.absolutePath,"versionName" to candidate.versionName,
                        "versionCode" to version(candidate),"sizeBytes" to size))
                }
                finished=null
            } catch (_: Exception) {
                partial?.delete(); finished?.delete()
                activity.runOnUiThread {
                    active.compareAndSet(cancel,null)
                    if(!closed) result.error(if(cancel.get()) "UPDATE_CANCELLED" else "UPDATE_DOWNLOAD",
                        if(cancel.get()) "Đã hủy tải cập nhật." else "Không tải hoặc xác minh được bản cập nhật trong 3 phút. Vui lòng thử lại.",null)
                }
            } finally { mainHandler.removeCallbacks(deadline); connection?.disconnect(); connection=null }
        }
    }
    fun close() { closed=true; active.get()?.set(true); connection?.disconnect(); mainHandler.removeCallbacksAndMessages(null); executor.shutdownNow(); channel.setMethodCallHandler(null) }
}
