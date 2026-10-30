package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class UpdatePolicyTest {
    private val origin = "https://api.example.test"
    private val path = "/api/v1/mobile/releases/6005/arm64-v8a.apk"
    private val hash = "ab".repeat(32)
    private fun request(base: String = origin, route: String = path, sha: String = hash,
                        size: Long = 123, version: Long = 6005) =
        UpdatePolicy.downloadUri(base, route, sha, size, version, 6004)
    private fun rejected(block: () -> Any?) {
        try { block(); fail("Unsafe update accepted") } catch (_: IllegalArgumentException) { }
    }
    @Test fun validReleaseIsSameOrigin() { assertEquals(origin + path, request().toString()) }
    @Test fun preservesExplicitHttpsPort() { assertEquals(8443, request(base="$origin:8443").port) }
    @Test fun rejectsHttp() = rejected { request(base="http://api.example.test") }
    @Test fun rejectsCredentials() = rejected { request(base="https://user:pass@api.example.test") }
    @Test fun rejectsForeignAbsoluteUrl() = rejected { request(route="https://evil.test$path") }
    @Test fun rejectsProtocolRelativeUrl() = rejected { request(route="//evil.test$path") }
    @Test fun rejectsTraversal() = rejected { request(route="/api/v1/mobile/releases/6005/../arm64-v8a.apk") }
    @Test fun rejectsEncodedTraversal() = rejected { request(route="/api/v1/mobile/releases/6005/%2e%2e/arm64-v8a.apk") }
    @Test fun rejectsQuery() = rejected { request(route="$path?token=secret") }
    @Test fun rejectsBaseFragment() = rejected { request(base="$origin/#bad") }
    @Test fun rejectsWrongVersionPath() = rejected { request(version=6006) }
    @Test fun rejectsUnsupportedAbi() = rejected { request(route="/api/v1/mobile/releases/6005/arm.apk") }
    @Test fun rejectsMalformedHash() = rejected { request(sha="xz".repeat(32)) }
    @Test fun rejectsEmptyBody() = rejected { request(size=0) }
    @Test fun rejectsHugeBody() = rejected { request(size=80L*1024*1024+1) }
    @Test fun rejectsDowngradeOrSameVersion() = rejected { request(version=6004) }
    @Test fun packageVersionAndSignerMustMatch() {
        UpdatePolicy.archive("vn.fruitvision", "vn.fruitvision", 6005, 6005, 6004,
            setOf(hash), setOf(hash), false)
    }
    @Test fun wrongPackageRejected() = rejected {
        UpdatePolicy.archive("evil.app", "vn.fruitvision", 6005,6005,6004,setOf(hash),setOf(hash),false)
    }
    @Test fun wrongSignerRejected() = rejected {
        UpdatePolicy.archive("app", "app",6005,6005,6004,setOf(hash),setOf("cd".repeat(32)),false)
    }
    @Test fun missingSignerRejected() = rejected {
        UpdatePolicy.archive("app", "app",6005,6005,6004,emptySet(),emptySet(),false)
    }
    @Test fun debugArchiveRejected() = rejected {
        UpdatePolicy.archive("app", "app",6005,6005,6004,setOf(hash),setOf(hash),true)
    }
    @Test fun archiveVersionMismatchRejected() = rejected {
        UpdatePolicy.archive("app", "app",6006,6005,6004,setOf(hash),setOf(hash),false)
    }
}
