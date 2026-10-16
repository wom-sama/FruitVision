package vn.mangodemo.mango_offline

import android.os.SystemClock
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class LiveCameraDeviceTest {
    @Test fun startupErrorIsPublishedBeforeStoppedSoUiDoesNotLoseItsCause() {
        val events = mutableListOf<String>()
        val failed = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        var session: LiveCameraSession? = null
        ActivityScenario.launch(CameraTestActivity::class.java).use { scenario ->
            try {
                scenario.onActivity { activity ->
                    val preview = LivePreviewView(activity)
                    activity.setContentView(preview)
                    session = LiveCameraSession(activity, activity, worker,
                        { throw IllegalStateException("Model unavailable fixture") }, {},
                        { event -> if (event["type"] == "state") events.add(event["state"] as String) })
                    session!!.start(preview, "back", 5) { error -> assertNotNull(error); failed.countDown() }
                }
                assertTrue(failed.await(5, TimeUnit.SECONDS))
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                assertEquals(listOf("starting", "error", "stopped"), events)
                assertFalse(session!!.active)
            } finally { scenario.onActivity { session?.stop() } }
        }
        worker.shutdown(); assertTrue(worker.awaitTermination(10, TimeUnit.SECONDS))
    }
    @Test fun actualCameraHasBoundedInferenceAndStopsRestartsAndBackgroundsCleanly() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.CAMERA").close()
        val worker = Executors.newSingleThreadExecutor()
        val count = AtomicInteger()
        val error = AtomicReference<String?>()
        val first = CountDownLatch(1)
        var session: LiveCameraSession? = null
        var engine: NativeInferenceEngine? = null
        var preview: LivePreviewView? = null
        val snapshots = mutableListOf<Map<String, Any>>()
        val thermalSamples = mutableListOf<Map<String, Any>>()
        val started = SystemClock.elapsedRealtime()
        val scenario = ActivityScenario.launch(CameraTestActivity::class.java)
        try {
            scenario.onActivity { activity ->
                preview = LivePreviewView(activity)
                activity.setContentView(preview, FrameLayout.LayoutParams(-1, -1))
                session = LiveCameraSession(activity, activity, worker,
                    { engine ?: NativeInferenceEngine(context).also { engine = it } },
                    { engine?.close(); engine = null },
                    { event ->
                        if (event["type"] == "frame") { count.incrementAndGet(); first.countDown() }
                        if (event["state"] == "error") error.set(event["message"] as String)
                    })
                preview!!.post { session!!.start(preview!!, "back", 30) { failure -> if (failure != null) error.set(failure.message) } }
            }
            assertTrue("Camera first frame timed out: ${error.get()}", first.await(20, TimeUnit.SECONDS))
            // Finite soak; stats exclude first 5 processed frames and retain at most 120 samples.
            repeat(12) { Thread.sleep(5000); snapshots.add(session!!.stats()) }
            assertNull("Camera failure", error.get())
            assertTrue(count.get() >= 40)
            assertTrue((snapshots.last()["sampleCount"] as Int) <= 120)
            assertTrue((snapshots.last()["inferenceFps"] as Double) <= 30.2)
            assertTrue((snapshots.last()["processed"] as Long) <= (snapshots.last()["delivered"] as Long))
            assertTrue("Unbounded PSS growth during live soak", snapshots.maxOf { it["pssMb"] as Double } -
                (snapshots[2]["pssMb"] as Double) < 64.0)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                fun thermalCommand(command: String) {
                    instrumentation.uiAutomation.executeShellCommand("cmd thermalservice $command").use { descriptor ->
                        java.io.FileInputStream(descriptor.fileDescriptor).use { it.readBytes() }
                    }
                }
                try {
                    thermalCommand("override-status 3")
                    Thread.sleep(5500)
                    thermalSamples.add(session!!.stats())
                    assertEquals(1, session!!.stats()["effectiveMaxFps"])
                } finally { thermalCommand("reset") }
                Thread.sleep(4500)
                thermalSamples.add(session!!.stats())
                assertEquals(30, session!!.stats()["effectiveMaxFps"])
            }
            val preRotateCount = count.get()
            scenario.onActivity { it.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            Thread.sleep(2500)
            assertTrue("Camera should continue after rotation", count.get() > preRotateCount)
            scenario.onActivity { it.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            Thread.sleep(2500)
            val stopped = CountDownLatch(1)
            scenario.onActivity { session!!.stop { stopped.countDown() } }
            assertTrue(stopped.await(10, TimeUnit.SECONDS))
            val afterStop = count.get()
            Thread.sleep(600)
            assertEquals("Late inference after stop", afterStop, count.get())
            val restarted = CountDownLatch(1)
            scenario.onActivity { session!!.start(preview!!, "back", 5) { failure -> assertNull(failure); restarted.countDown() } }
            assertTrue(restarted.await(10, TimeUnit.SECONDS))
            val deadline = SystemClock.elapsedRealtime() + 10_000
            while (count.get() <= afterStop && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50)
            assertTrue(count.get() > afterStop)
            scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            Thread.sleep(1000)
            assertFalse("Session should stop on host background", session!!.active)
            val backgroundCount = count.get()
            Thread.sleep(500)
            assertEquals(backgroundCount, count.get())
            File(context.filesDir, "live_camera_benchmark.json").writeText(JSONObject(mapOf(
                "device" to android.os.Build.MODEL, "abi" to android.os.Build.SUPPORTED_ABIS.first(),
                "hardware" to "Android emulator, emulated back camera (not fruit footage)",
                "elapsedMs" to SystemClock.elapsedRealtime() - started,
                "snapshots" to snapshots, "thermalSamples" to thermalSamples,
                "thermalTest" to "emulator forced thermal status 3 then reset, not physical heating",
                "framesBeforeStop" to afterStop,
                "stopRestartBackgroundPassed" to true)).toString(2))
        } finally {
            scenario.onActivity { session?.stop() }
            scenario.close()
            worker.shutdown(); assertTrue(worker.awaitTermination(10, TimeUnit.SECONDS))
        }
    }
}
