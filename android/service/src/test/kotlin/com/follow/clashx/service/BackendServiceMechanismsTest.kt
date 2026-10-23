package com.follow.clashx.service

import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.modules.SharedNotificationContent
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class BackendServiceMechanismsTest {
    private class FakeResource(var idle: Boolean = true, var stopAccepted: Boolean = true) : BackendForegroundResource {
        override var destroyed = false
        var stops = 0
        var startId = 1
        var stoppedStartId = 0
        override suspend fun handleStart(options: VpnOptions) {}
        override suspend fun handleStop() {}
        override fun finishIfIdle() {
            BackendForegroundHold.retireIfIdle(this, { idle }, { startId }) { stoppedStartId = it; stops++; stopAccepted }
        }
    }

    private fun withResource(resource: FakeResource, block: suspend (FakeResource) -> Unit) = runBlocking {
        BackendForegroundHold.created(resource)
        try { block(resource) } finally { BackendForegroundHold.destroyed(resource) }
    }

    @Test fun bothServicesMapNotificationStopToRuntimeStop() {
        assertEquals("runtime.stop", ServiceStartCommand.backendMethod("com.makriq.flclash.service.STOP"))
        assertFalse(ServiceStartCommand.sticky("runtime.stop"))
        assertEquals("runtime.recover", ServiceStartCommand.backendMethod(null))
        assertEquals("runtime.recover", ServiceStartCommand.backendMethod("android.net.VpnService"))
        assertTrue(ServiceStartCommand.sticky("runtime.recover"))
        assertNull(ServiceStartCommand.backendMethod(AndroidBackendPlatform.ACTION_APPLY))
        assertNull(ServiceStartCommand.backendMethod(BackendForegroundHold.ACTION_HOLD))
        assertNull(ServiceStartCommand.backendMethod(BackendForegroundHold.ACTION_RUNTIME))
    }

    @Test fun stoppingServiceNoLongerGrantsHoldsOrStarts() = withResource(FakeResource()) { resource ->
        assertTrue(BackendForegroundHold.isLive(resource))
        resource.finishIfIdle()
        assertEquals(1, resource.stops)
        assertFalse(BackendForegroundHold.isLive(resource))
        assertNull(withTimeoutOrNull(200L) { BackendForegroundHold.awaitService(FakeResource::class.java) })
        // A late duplicate finish does not stop twice.
        resource.finishIfIdle()
        assertEquals(1, resource.stops)
    }

    @Test fun newerStartCommandKeepsInstanceLive() = withResource(FakeResource(stopAccepted = false)) { resource ->
        resource.startId = 7
        resource.finishIfIdle()
        assertEquals(1, resource.stops)
        // The id read while retiring is the one passed to stopSelfResult.
        assertEquals(7, resource.stoppedStartId)
        assertTrue(BackendForegroundHold.isLive(resource))
        assertSame(resource, BackendForegroundHold.awaitService(FakeResource::class.java))
    }

    @Test fun busyOrHeldServiceIsNotRetired() = withResource(FakeResource(idle = false)) { resource ->
        resource.finishIfIdle()
        assertEquals(0, resource.stops)
        resource.idle = true
        BackendForegroundHold.acquire("operation")
        resource.finishIfIdle()
        assertEquals(0, resource.stops)
        assertTrue(BackendForegroundHold.isLive(resource))
        // Releasing the last hold retires the idle host.
        BackendForegroundHold.release("operation")
        assertEquals(1, resource.stops)
        assertFalse(BackendForegroundHold.isLive(resource))
    }

    @Test fun destroyedServiceIsNotRegisteredAgain() {
        val resource = FakeResource().apply { destroyed = true }
        BackendForegroundHold.created(resource)
        assertFalse(BackendForegroundHold.isLive(resource))
    }

    @Test fun onlyStateEventsRefreshPresentation() {
        assertTrue(BackendEvents.refreshesPresentation("backend"))
        assertTrue(BackendEvents.refreshesPresentation("delay"))
        for (type in listOf("log", "request", "loaded", "runtimeLog", "backendPlatform", "", null)) {
            assertFalse(type.toString(), BackendEvents.refreshesPresentation(type))
        }
    }

    @Test fun normalizesProjectedThemeMode() {
        assertEquals("dark", BackendEvents.themeMode("dark"))
        assertEquals("light", BackendEvents.themeMode("ThemeMode.light"))
        assertEquals("system", BackendEvents.themeMode("system"))
        assertEquals("system", BackendEvents.themeMode(""))
        assertEquals("system", BackendEvents.themeMode(null))
        assertEquals("system", BackendEvents.themeMode("sepia"))
    }

    @Test fun sharedNotificationPostsEachContentOnce() {
        var current = NotificationParams(title = "Profile", stopText = "Stop")
        val posts = mutableListOf<NotificationParams>()
        val content = SharedNotificationContent { current }
        val show: (NotificationParams) -> Boolean = { posts.add(it) }
        assertTrue(content.post(force = true, show))
        // Both services observe the same unchanged params: nothing is re-posted.
        assertFalse(content.post(force = false, show))
        assertFalse(content.post(force = false, show))
        current = current.copy(title = "Other")
        assertTrue(content.post(force = false, show))
        assertFalse(content.post(force = false, show))
        // startForeground always posts, with the current title, never a placeholder.
        assertTrue(content.post(force = true, show))
        assertEquals(listOf("Profile", "Other", "Other"), posts.map { it.title })
        // A failed post is retried by the next observer.
        current = current.copy(title = "Third")
        assertFalse(content.post(force = false) { false })
        assertTrue(content.post(force = false, show))
    }
}
