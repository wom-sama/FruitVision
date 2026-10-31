package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class LiveFrameGeometryTest {
    @Test fun preview_is_bounded_preserves_aspect_and_never_upscales() {
        assertEquals(960 to 540,LiveFrameGeometry.size(1920,1080))
        assertEquals(540 to 960,LiveFrameGeometry.size(1080,1920))
        assertEquals(640 to 480,LiveFrameGeometry.size(640,480))
        assertEquals(1 to 960,LiveFrameGeometry.size(1,2000))
    }
    @Test fun invalid_surface_dimensions_are_rejected() {
        for((w,h) in listOf(0 to 1,1 to 0,-1 to 40)) {
            try { LiveFrameGeometry.size(w,h);fail("Invalid geometry accepted") } catch(_:IllegalArgumentException) {}
        }
    }
}
