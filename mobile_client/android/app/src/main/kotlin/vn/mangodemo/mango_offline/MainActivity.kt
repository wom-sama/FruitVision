package vn.mangodemo.mango_offline

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.io.File
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private var updater: AppUpdater? = null
    private var mediaResult: MethodChannel.Result? = null
    private var captureFile: File? = null
    private var requestedMediaType = "image"
    private val pickerRequest = 4101
    private val captureRequest = 4102
    private val uploadCache by lazy { File(cacheDir, "fv_uploads").apply { mkdirs() } }
    private val captureCache by lazy { File(cacheDir, "fv_capture").apply { mkdirs() } }
    private val alias = "fruitvision.session.v2"
    private val preferences by lazy { getSharedPreferences("api_session_v2", MODE_PRIVATE) }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val updateChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.fruitvision/updates")
        updater = AppUpdater(this, updateChannel).also { handler -> updateChannel.setMethodCallHandler(handler::handle) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.fruitvision/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage", "pickVideo", "captureImage" -> {
                        if (mediaResult != null) result.error("MEDIA_BUSY", "Đang chọn một tệp khác.", null)
                        else {
                            mediaResult = result
                            requestedMediaType = if (call.method == "pickVideo") "video" else "image"
                            try {
                                if (call.method == "captureImage") {
                                    val file = File.createTempFile("camera_", ".jpg", captureCache)
                                    captureFile = file
                                    val uri = FileProvider.getUriForFile(this, "$packageName.media", file)
                                    val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                                        putExtra(MediaStore.EXTRA_OUTPUT, uri)
                                        clipData = ClipData.newRawUri("FruitVision camera", uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                                    }
                                    startActivityForResult(intent, captureRequest)
                                } else {
                                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = if (requestedMediaType == "video") "video/mp4" else "image/*"
                                        if (requestedMediaType == "image") putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/jpeg", "image/png"))
                                    }
                                    startActivityForResult(intent, pickerRequest)
                                }
                            } catch (_: Exception) {
                                captureFile?.delete(); captureFile = null; mediaResult = null
                                result.error("MEDIA_PICKER", "Không mở được trình chọn tệp hoặc máy ảnh.", null)
                            }
                        }
                    }
                    "delete" -> {
                        val path = call.argument<String>("path")
                        mediaExecutor.execute {
                            try {
                                val file = File(path ?: error("Missing path")).canonicalFile
                                require(file.parentFile == uploadCache.canonicalFile || file.parentFile == captureCache.canonicalFile)
                                if (file.exists()) check(file.delete())
                                runOnUiThread { result.success(null) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("MEDIA_DELETE", "Không xóa được bản sao tạm.", null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // Recover abandoned private copies after process death; never touch other cache directories.
        mediaExecutor.execute {
            val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000
            listOf(uploadCache, captureCache).forEach { directory ->
                directory.listFiles()?.filter { it.isFile && it.lastModified() < cutoff }?.forEach { it.delete() }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.fruitvision/session_vault")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> {
                            val stored = preferences.getString("blob", null)
                            if (stored == null) result.success(null)
                            else {
                                val parts = stored.split(":", limit = 2)
                                require(parts.size == 2)
                                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                                result.success(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
                            }
                        }
                        "write" -> {
                            val value = call.arguments as? String ?: error("Missing session")
                            require(value.length <= 16384)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, key())
                            val blob = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
                                Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
                            check(preferences.edit().putString("blob", blob).commit())
                            result.success(null)
                        }
                        "clear" -> {
                            check(preferences.edit().remove("blob").commit())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    // Corrupt ciphertext never becomes a usable session or appears in logs.
                    if (call.method == "read") preferences.edit().remove("blob").commit()
                    result.error("SESSION_VAULT", "Cannot access encrypted session", null)
                }
            }
    }

    @Deprecated("Activity result API retained to avoid an additional plugin dependency")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickerRequest && requestCode != captureRequest) return
        val result = mediaResult ?: return
        mediaResult = null
        val captured = captureFile; captureFile = null
        if (resultCode != Activity.RESULT_OK) { captured?.delete(); result.success(null); return }
        val mediaType = requestedMediaType
        mediaExecutor.execute {
            var local: File? = captured
            try {
                val contentType: String
                val name: String
                if (requestCode == captureRequest) {
                    val capture = captured ?: error("Missing capture")
                    local = capture
                    contentType = "image/jpeg"; name = "camera.jpg"
                    val signature = capture.inputStream().use { input -> byteArrayOf(input.read().toByte(), input.read().toByte()) }
                    require(signature[0] == 0xff.toByte() && signature[1] == 0xd8.toByte())
                } else {
                    val uri: Uri = data?.data ?: error("Missing document")
                    contentType = contentResolver.getType(uri) ?: error("Unknown media")
                    require(if (mediaType == "video") contentType == "video/mp4" else contentType in setOf("image/jpeg", "image/png"))
                    var displayName = "selected-media"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) displayName = cursor.getString(0) ?: displayName
                    }
                    name = displayName.replace(Regex("[\\p{Cntrl}]"), " ").take(120)
                    val extension = when (contentType) { "video/mp4" -> ".mp4"; "image/png" -> ".png"; else -> ".jpg" }
                    val copy = File.createTempFile("selected_", extension, uploadCache)
                    local = copy
                    val maxBytes = if (mediaType == "video") 80L * 1024 * 1024 else 12L * 1024 * 1024
                    contentResolver.openInputStream(uri)?.use { input ->
                        copy.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024); var total = 0L
                            while (true) {
                                check(!Thread.currentThread().isInterrupted)
                                val count = input.read(buffer); if (count < 0) break
                                total += count; require(total <= maxBytes)
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: error("Unreadable document")
                }
                val file = local ?: error("Missing file")
                val maxBytes = if (mediaType == "video") 80L * 1024 * 1024 else 12L * 1024 * 1024
                require(file.length() in 1..maxBytes)
                val payload = mapOf("path" to file.absolutePath, "name" to name, "bytes" to file.length(),
                    "mediaType" to mediaType, "contentType" to contentType)
                runOnUiThread { result.success(payload) }
            } catch (_: Exception) {
                local?.delete()
                runOnUiThread { result.error("MEDIA_FILE", "Chọn JPEG/PNG tối đa 12 MiB hoặc MP4 tối đa 80 MiB.", null) }
            }
        }
    }

    override fun onDestroy() {
        updater?.close(); updater = null
        captureFile?.delete(); captureFile = null
        mediaResult?.error("MEDIA_CANCELLED", "Đã đóng trình chọn tệp.", null); mediaResult = null
        mediaExecutor.shutdownNow()
        super.onDestroy()
    }
}
