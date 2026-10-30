package vn.mangodemo.mango_offline

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-only E2EE key bags. No network and no server/public-backup path. */
internal class SecretKeyVault(context:Context) {
    private val preferences=context.getSharedPreferences("fv_e2ee_keys_v1",Context.MODE_PRIVATE)
    private val keyAlias="fruitvision.e2ee.keybag.v1"
    private fun key():SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias,null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(keyAlias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun scope(call:MethodCall):ByteArray {
        val uri=URI(call.argument<String>("origin") ?: error("Missing origin"))
        require(uri.scheme=="https" && !uri.host.isNullOrEmpty() && uri.userInfo==null && uri.rawQuery==null && uri.rawFragment==null && uri.path in listOf("","/"))
        val id=UUID.fromString(call.argument<String>("userId") ?: error("Missing user"))
        val origin="https://${uri.host.lowercase(java.util.Locale.ROOT)}" + if(uri.port!=-1 && uri.port!=443) ":${uri.port}" else ""
        return "FruitVision.e2ee.keybag.v1\n$origin\n$id".toByteArray(Charsets.UTF_8)
    }
    fun handle(call:MethodCall,result:MethodChannel.Result) {
        try {
            val aad=scope(call)
            val name=MessageDigest.getInstance("SHA-256").digest(aad).joinToString("") { "%02x".format(it) }
            when(call.method) {
                "read" -> {
                    val encoded=preferences.getString(name,null)
                    if(encoded==null) { result.success(null); return }
                    require(encoded.length<=24000)
                    val packed=Base64.decode(encoded,Base64.NO_WRAP); require(packed.size in 29..16412)
                    val cipher=Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,packed.copyOfRange(0,12))); cipher.updateAAD(aad)
                    val clear=cipher.doFinal(packed,12,packed.size-12)
                    try { require(clear.size<=16384); result.success(String(clear,Charsets.UTF_8)) } finally { clear.fill(0) }
                }
                "write" -> {
                    val value=call.argument<String>("value") ?: error("Missing key bag")
                    val clear=value.toByteArray(Charsets.UTF_8); require(clear.size in 1..16384)
                    try {
                        val cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key()); cipher.updateAAD(aad)
                        require(cipher.iv.size==12)
                        val packed=cipher.iv+cipher.doFinal(clear)
                        check(preferences.edit().putString(name,Base64.encodeToString(packed,Base64.NO_WRAP)).commit())
                    } finally { clear.fill(0) }
                    result.success(null)
                }
                "delete" -> { check(preferences.edit().remove(name).commit()); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_:Exception) {
            // Never silently replace a corrupt bag: doing so would destroy access to message history.
            result.error("SECRET_KEY_VAULT","Không mở được khóa hội thoại bí mật trên thiết bị này. Khóa không được lưu trên máy chủ; không tự tạo khóa thay thế.",null)
        }
    }
}
