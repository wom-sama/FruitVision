package vn.mangodemo.mango_offline
import java.io.File
internal object EvidencePolicy {
    const val MAX_BYTES = 5L * 1024 * 1024
    fun matches(mime: String, header: ByteArray): Boolean {
        val signature = when(mime) {
            "image/jpeg" -> byteArrayOf(0xff.toByte(),0xd8.toByte(),0xff.toByte())
            "image/png" -> byteArrayOf(0x89.toByte(),0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a)
            "application/pdf" -> "%PDF-".toByteArray(Charsets.US_ASCII)
            else -> return false
        }
        return header.size >= signature.size && signature.indices.all { header[it] == signature[it] }
    }
    fun validate(file: File, root: File, mime: String) {
        val actual = file.canonicalFile
        require(actual.parentFile == root.canonicalFile && actual.isFile && actual.length() in 1..MAX_BYTES)
        val header = actual.inputStream().use { input -> val bytes = ByteArray(8); val count = input.read(bytes); bytes.copyOf(count.coerceAtLeast(0)) }
        require(matches(mime,header))
    }
}
