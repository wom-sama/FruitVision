package vn.mangodemo.mango_offline

import android.app.Activity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry

/** Instrumentation host only; absent from release APK. */
class CameraTestActivity : Activity(), LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry
    override fun onCreate(state: android.os.Bundle?) { super.onCreate(state); registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE) }
    override fun onStart() { super.onStart(); registry.handleLifecycleEvent(Lifecycle.Event.ON_START) }
    override fun onResume() { super.onResume(); registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME) }
    override fun onPause() { registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE); super.onPause() }
    override fun onStop() { registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP); super.onStop() }
    override fun onDestroy() { registry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY); super.onDestroy() }
}
