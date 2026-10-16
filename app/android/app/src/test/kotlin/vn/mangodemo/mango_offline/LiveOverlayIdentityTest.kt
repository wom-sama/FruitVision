package vn.mangodemo.mango_offline

import org.junit.Assert.*
import org.junit.Test

class LiveOverlayIdentityTest {
    @Test fun lateIdsCannotBeAppliedToNewerGeometryOrClosedSession() {
        val identity = LiveOverlayIdentity()
        identity.frame(100, 2)
        assertTrue(identity.accepts(100, listOf(7, 2)))
        identity.frame(200, 2)
        assertFalse(identity.accepts(100, listOf(7, 2)))
        assertTrue(identity.accepts(200, listOf(2, 7)))
        identity.clear()
        assertFalse(identity.accepts(200, listOf(2, 7)))
    }
    @Test fun duplicateOrMismatchedIdsAreRejectedRatherThanDrawingFalseIdentity() {
        val identity = LiveOverlayIdentity()
        identity.frame(100, 2)
        assertThrows(IllegalArgumentException::class.java) { identity.accepts(100, listOf(1, 1)) }
        assertThrows(IllegalArgumentException::class.java) { identity.accepts(100, listOf(0, 2)) }
        assertThrows(IllegalArgumentException::class.java) { identity.accepts(100, listOf(1)) }
    }
}
