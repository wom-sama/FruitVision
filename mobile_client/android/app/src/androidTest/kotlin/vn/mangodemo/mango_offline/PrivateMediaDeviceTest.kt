package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Actual Android Keystore and image-codec tests; does not alter existing user key bags. */
class PrivateMediaDeviceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val origin = "https://fruitvision.example"
    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { error = code }
        override fun notImplemented() { error = "NOT_IMPLEMENTED" }
    }
    private fun call(vault: SecretKeyVault, method: String, user: String, value: String? = null, host: String = origin): Reply {
        val args = mutableMapOf<String, Any>("origin" to host, "userId" to user)
        value?.let { args["value"] = it }
        return Reply().also { vault.handle(MethodCall(method, args), it) }
    }
    @Test fun keyBagPersistsAcrossInstancesAndDeleteIsScoped() {
        val user = UUID.randomUUID().toString()
        val other = UUID.randomUUID().toString()
        val clear = "{\"test\":\"${UUID.randomUUID()}\"}"
        val vault = SecretKeyVault(context)
        try {
            assertNull(call(vault, "read", user).value)
            assertNull(call(vault, "write", user, clear).error)
            assertEquals(clear, call(SecretKeyVault(context), "read", user).value)
            assertNull(call(vault, "read", other).value)
            assertNull(call(vault, "read", user, host="https://other.example").value)
            val stored = context.getSharedPreferences("fv_e2ee_keys_v1", 0).all.values
            assertFalse(stored.contains(clear))
            assertNull(call(vault, "delete", user).error)
            assertNull(call(vault, "read", user).value)
        } finally { call(vault, "delete", user); call(vault, "delete", other) }
    }
    @Test fun corruptedKeyBagFailsClosedAndIsNotReplaced() {
        val user = UUID.randomUUID().toString()
        val vault = SecretKeyVault(context)
        val aad = "FruitVision.e2ee.keybag.v1\n$origin\n$user".toByteArray()
        val name = MessageDigest.getInstance("SHA-256").digest(aad).joinToString("") { "%02x".format(it) }
        val prefs = context.getSharedPreferences("fv_e2ee_keys_v1", 0)
        try {
            assertNull(call(vault, "write", user, "{\"test\":true}").error)
            val packed = prefs.getString(name, null)!!
            val corrupt = "!" + packed.drop(1)
            assertTrue(prefs.edit().putString(name, corrupt).commit())
            assertEquals("SECRET_KEY_VAULT", call(vault, "read", user).error)
            assertEquals(corrupt, prefs.getString(name, null))
        } finally { call(vault, "delete", user) }
    }
    @Test fun unsafeOriginAndOversizeKeyBagAreRejected() {
        val user = UUID.randomUUID().toString()
        val vault = SecretKeyVault(context)
        try {
            for (host in listOf("http://fruitvision.example", "$origin/path", "$origin?x=y", "https://a@fruitvision.example"))
                assertEquals("SECRET_KEY_VAULT", call(vault, "write", user, "{}", host).error)
            assertEquals("SECRET_KEY_VAULT", call(vault, "write", user, "x".repeat(16385)).error)
            assertNull(call(vault, "read", user).value)
        } finally { call(vault, "delete", user) }
    }
    @Test fun sharedPhotoIsOrientedBoundedAndStripsLocation() {
        val directory = File(context.cacheDir, "photo-test-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val input = File(directory, "source.jpg")
            val bitmap = Bitmap.createBitmap(3000, 1000, Bitmap.Config.ARGB_8888)
            try { input.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) } }
            finally { bitmap.recycle() }
            ExifInterface(input.path).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                setAttribute(ExifInterface.TAG_GPS_LATITUDE, "10/1,0/1,0/1")
                saveAttributes()
            }
            val output = PhotoPreparation.prepare(input, directory, 2048, 5L * 1024 * 1024)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(output.path, bounds)
            assertEquals(2048, bounds.outHeight)
            assertTrue(bounds.outWidth in 680..684)
            assertTrue(output.length() in 1..5L * 1024 * 1024)
            val exif = ExifInterface(output.path)
            assertNull(exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
            assertTrue(exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) in listOf(0, 1))
        } finally { directory.deleteRecursively() }
    }
}
