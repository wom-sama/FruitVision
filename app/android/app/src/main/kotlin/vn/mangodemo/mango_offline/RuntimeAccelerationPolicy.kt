package vn.mangodemo.mango_offline

internal object RuntimeAccelerationPolicy {
    fun workerThreads(availableCores: Int, lowMemory: Boolean): Int =
        if (lowMemory) 1 else availableCores.coerceIn(1, 2)

    fun candidates(availableCores: Int, apiLevel: Int): List<String> = buildList {
        if (availableCores >= 4) add("CPU4")
        // CPU_DISABLED is supported from API29. Never relax computation to FP16.
        if (apiLevel >= 29) add("NNAPI")
        add("XNNPACK")
    }
    fun useCandidate(cpuMs: List<Double>, candidateMs: List<Double>, parityPassed: Boolean): Boolean {
        if (!parityPassed || cpuMs.size != 3 || candidateMs.size != 3 ||
            (cpuMs + candidateMs).any { !it.isFinite() || it <= 0 }) return false
        // A faster median alone can conceal stalls; require improvement in the worst sample too.
        return candidateMs.sorted()[1] < cpuMs.sorted()[1] * .85 && candidateMs.max() < cpuMs.max() * .85
    }
}
