package com.follow.clashx.plugins

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class PackageIconFilesTest {
    @Test fun cacheKeysSeparatePackageUpdatesAndCannotEscapeTheDirectory() {
        val key = iconCacheKey("../../profile.yaml", 10)
        assertTrue(key.matches(Regex("[0-9a-f]{64}_10\\.png")))
        assertEquals(key, iconCacheKey("../../profile.yaml", 10))
        assertNotEquals(key, iconCacheKey("../../profile.yaml", 11))
        assertNotEquals(key, iconCacheKey("com.android.settings", 10))
    }
}
