package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class EvidencePolicyTest {
    private fun rejected(block: () -> Unit) { try { block(); fail("Unsafe evidence accepted") } catch (_: IllegalArgumentException) {} }
    @Test fun supportedMagicIsRequiredInsteadOfExtensionOnly() {
        assertTrue(EvidencePolicy.matches("application/pdf", "%PDF-1.7".toByteArray()))
        assertTrue(EvidencePolicy.matches("image/jpeg", byteArrayOf(0xff.toByte(),0xd8.toByte(),0xff.toByte())))
        assertTrue(EvidencePolicy.matches("image/png", byteArrayOf(0x89.toByte(),0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a)))
        assertFalse(EvidencePolicy.matches("image/jpeg", "%PDF-1.7".toByteArray()))
        assertFalse(EvidencePolicy.matches("text/html", "<script>".toByteArray()))
        assertFalse(EvidencePolicy.matches("image/png", byteArrayOf(0x89.toByte(),0x50)))
    }
    @Test fun onlyOwnedExactCacheFilesMayBeOpened() {
        val temp = Files.createTempDirectory("evidence-policy").toFile()
        try {
            val root = File(temp,"fv_evidence").apply { mkdirs() }
            val good = File(root,"a.pdf").apply { writeText("%PDF-1.7") }
            EvidencePolicy.validate(good,root,"application/pdf")
            val outside = File(temp,"outside.pdf").apply { writeText("%PDF-1.7") }
            rejected { EvidencePolicy.validate(outside,root,"application/pdf") }
            val nested = File(root,"sub").apply { mkdirs() }
            rejected { EvidencePolicy.validate(File(nested,"file.pdf").apply { writeText("%PDF-1.7") },root,"application/pdf") }
            rejected { EvidencePolicy.validate(File(root,"empty.pdf").apply { writeText("") },root,"application/pdf") }
            val huge = File(root,"huge.pdf").apply { outputStream().use { it.write("%PDF-1.7".toByteArray()); it.write(ByteArray(5*1024*1024)) } }
            rejected { EvidencePolicy.validate(huge,root,"application/pdf") }
        } finally { temp.deleteRecursively() }
    }
}
