package vn.mangodemo.mango_offline

import java.net.URI

/** Pure request/archive rules; the installer still performs Android signature verification. */
internal object UpdatePolicy {
    const val MAX_BYTES = 80L * 1024 * 1024
    fun downloadUri(base: String, path: String, sha: String, size: Long,
                    version: Long, installed: Long): URI {
        val origin = URI(base)
        require(origin.scheme == "https" && !origin.host.isNullOrEmpty() && origin.userInfo == null)
        require(origin.rawQuery == null && origin.rawFragment == null)
        require(size in 1..MAX_BYTES && sha.matches(Regex("[a-fA-F0-9]{64}")))
        require(version > installed)
        require(path.matches(Regex("/api/v1/mobile/releases/$version/(arm64-v8a|armeabi-v7a|x86_64)\\.apk")))
        return origin.resolve(path).also {
            require(it.scheme == origin.scheme && it.host == origin.host && it.port == origin.port)
        }
    }
    fun archive(actualPackage: String, installedPackage: String, actualVersion: Long,
                expectedVersion: Long, installedVersion: Long, signers: Set<String>,
                installedSigners: Set<String>, debuggable: Boolean) {
        require(actualPackage == installedPackage && actualVersion == expectedVersion && actualVersion > installedVersion)
        require(signers.isNotEmpty() && signers == installedSigners && !debuggable)
    }
}
