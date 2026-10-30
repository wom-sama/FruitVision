package vn.mangodemo.mango_offline

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.hardware.biometrics.BiometricManager
import android.hardware.fingerprint.FingerprintManager
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.RSAKeyGenParameterSpec
import java.util.UUID

/** The server verifies a one-use signature. A local boolean is never sent as authentication proof. */
internal class DeviceBiometrics(private val activity: Activity) {
    private val preferences=activity.getSharedPreferences("fv_biometric_devices_v1",Activity.MODE_PRIVATE)
    private val store get()=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private var pending:MethodChannel.Result?=null
    private var cancellation:CancellationSignal?=null
    private fun alias(call:MethodCall):String {
        val raw=call.argument<String>("origin") ?: error("Missing origin")
        val uri=URI(raw)
        require(uri.scheme=="https" && !uri.host.isNullOrEmpty() && uri.userInfo==null && uri.rawQuery==null && uri.rawFragment==null && uri.path in listOf("","/"))
        val email=call.argument<String>("email")?.trim()?.lowercase(java.util.Locale.ROOT) ?: error("Missing email")
        require(email.length in 3..254 && email.contains('@') && email.none { it.isISOControl() })
        val origin="https://${uri.host.lowercase(java.util.Locale.ROOT)}" + if(uri.port!=-1 && uri.port!=443) ":${uri.port}" else ""
        val digest=MessageDigest.getInstance("SHA-256").digest("$origin\n$email".toByteArray(Charsets.UTF_8))
        return "fruitvision.biometric.v1." + digest.joinToString("") { "%02x".format(it) }
    }
    @Suppress("DEPRECATION")
    private fun available():Boolean {
        return when {
            Build.VERSION.SDK_INT>=30 -> activity.getSystemService(BiometricManager::class.java).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)==BiometricManager.BIOMETRIC_SUCCESS
            Build.VERSION.SDK_INT>=29 -> activity.getSystemService(BiometricManager::class.java).canAuthenticate()==BiometricManager.BIOMETRIC_SUCCESS
            Build.VERSION.SDK_INT>=28 -> activity.getSystemService(FingerprintManager::class.java)?.let { it.isHardwareDetected && it.hasEnrolledFingerprints() } ?: false
            else -> false // Optional sign-in remains unavailable on Android26/27; password+email OTP still works.
        }
    }
    private fun info(name:String):Map<String,Any?> {
        val public=store.getCertificate(name)?.publicKey?.encoded
        var device=preferences.getString(name,null)
        if(device==null) { device=UUID.randomUUID().toString(); check(preferences.edit().putString(name,device).commit()) }
        return mapOf("available" to available(),"enrolled" to (public!=null),"deviceId" to device,
            "label" to (Build.MANUFACTURER+" "+Build.MODEL).take(100),"publicKey" to public?.let { Base64.encodeToString(it,Base64.NO_WRAP) })
    }
    fun handle(call:MethodCall,result:MethodChannel.Result) {
        try {
            val name=alias(call)
            when(call.method) {
                "info" -> result.success(info(name))
                "createKey" -> {
                    require(available())
                    if(pending!=null) { result.error("BIOMETRIC_BUSY","Một yêu cầu xác thực đang mở.",null); return }
                    val builder=KeyGenParameterSpec.Builder(name,KeyProperties.PURPOSE_SIGN)
                        .setAlgorithmParameterSpec(RSAKeyGenParameterSpec(2048,RSAKeyGenParameterSpec.F4))
                        .setDigests(KeyProperties.DIGEST_SHA256).setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                        .setUserAuthenticationRequired(true).setInvalidatedByBiometricEnrollment(true)
                    if(Build.VERSION.SDK_INT>=30) builder.setUserAuthenticationParameters(0,KeyProperties.AUTH_BIOMETRIC_STRONG)
                    else @Suppress("DEPRECATION") builder.setUserAuthenticationValidityDurationSeconds(-1)
                    KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA,"AndroidKeyStore").apply { initialize(builder.build()) }.generateKeyPair()
                    result.success(info(name))
                }
                "sign" -> {
                    require(available() && Build.VERSION.SDK_INT>=28)
                    if(pending!=null) { result.error("BIOMETRIC_BUSY","Một yêu cầu xác thực đang mở.",null); return }
                    val payload=call.argument<String>("payload") ?: error("Missing payload")
                    val bytes=payload.toByteArray(Charsets.UTF_8); require(bytes.size in 1..4096)
                    val key=store.getKey(name,null) as? PrivateKey ?: error("Key missing")
                    val signature=Signature.getInstance("SHA256withRSA").apply { initSign(key) }
                    pending=result; prompt(signature,bytes)
                }
                "deleteKey" -> { require(pending==null); store.deleteEntry(name); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_:Exception) { result.error("BIOMETRIC_UNAVAILABLE","Không dùng được khóa sinh trắc học. Hãy đăng nhập bằng mật khẩu và mã email; có thể cần bật lại tính năng sau khi thay đổi vân tay.",null) }
    }
    @android.annotation.TargetApi(28)
    private fun prompt(signature:Signature,payload:ByteArray) {
        val builder=BiometricPrompt.Builder(activity).setTitle("Đăng nhập FruitVision")
            .setSubtitle("Xác thực khóa riêng trên thiết bị")
            .setNegativeButton("Hủy",activity.mainExecutor) { _,_ -> fail("Đã hủy xác thực.") }
        if(Build.VERSION.SDK_INT>=30) builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        val signal=CancellationSignal(); cancellation=signal
        try {
            builder.build().authenticate(BiometricPrompt.CryptoObject(signature),signal,activity.mainExecutor,object:BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(code:Int,message:CharSequence) { fail("Xác thực chưa hoàn tất. Bạn có thể dùng mật khẩu và mã email.") }
                override fun onAuthenticationSucceeded(result:BiometricPrompt.AuthenticationResult) {
                    val reply=pending ?: return
                    try {
                        val signed=result.cryptoObject?.signature ?: error("Missing cryptographic proof")
                        signed.update(payload); val proof=Base64.encodeToString(signed.sign(),Base64.NO_WRAP)
                        pending=null; cancellation=null; reply.success(proof)
                    } catch (_:Exception) { fail("Không ký được yêu cầu xác thực. Hãy đăng nhập bằng mật khẩu và mã email.") }
                }
            })
        } catch (_:Exception) { fail("Không mở được xác thực sinh trắc học.") }
    }
    private fun fail(message:String) { val reply=pending ?: return; pending=null; cancellation=null; reply.error("BIOMETRIC_CANCELLED",message,null) }
    fun close() { val old=cancellation; fail("Đã đóng yêu cầu xác thực."); old?.cancel() }
}
