package com.follow.clashx

import org.junit.Assert.*
import org.junit.Test

class LauncherSwitchTest {
    private val names = listOf("LauncherLight", "LauncherDark")

    @Test fun `enable replacement before disabling old entry`() {
        val calls = mutableListOf<Pair<String, Boolean>>()
        assertFalse(LauncherSwitch.apply("LauncherDark", names, emptySet()) { name, value -> calls.add(name to value) })
        assertEquals(listOf("LauncherDark" to true, "LauncherLight" to false), calls)
    }

    @Test fun `active alias is retained until its task disappears`() {
        val calls = mutableListOf<Pair<String, Boolean>>()
        assertTrue(LauncherSwitch.apply("LauncherDark", names, setOf("LauncherLight")) { n, v -> calls.add(n to v) })
        assertEquals(listOf("LauncherDark" to true), calls)
        calls.clear()
        assertFalse(LauncherSwitch.apply("LauncherDark", names, emptySet()) { n, v -> calls.add(n to v) })
        assertEquals(listOf("LauncherDark" to true, "LauncherLight" to false), calls)
    }

    @Test fun `failed enable preserves old entry and asks for retry`() {
        val calls = mutableListOf<String>()
        assertTrue(LauncherSwitch.apply("LauncherDark", names, emptySet()) { n, _ -> calls.add(n); throw IllegalStateException() })
        assertEquals(listOf("LauncherDark"), calls)
    }

    @Test fun `partial failure is reconciled using the newly selected theme`() {
        assertTrue(LauncherSwitch.apply("LauncherDark", names, emptySet()) { _, enabled -> if (!enabled) throw IllegalStateException() })
        val calls = mutableListOf<Pair<String, Boolean>>()
        assertFalse(LauncherSwitch.apply("LauncherLight", names, emptySet()) { n, v -> calls.add(n to v) })
        assertEquals(listOf("LauncherLight" to true, "LauncherDark" to false), calls)
    }

    @Test fun `unknown task state never disables existing entry`() {
        val calls = mutableListOf<Pair<String, Boolean>>()
        assertTrue(LauncherSwitch.apply("LauncherDark", names, null) { n, v -> calls.add(n to v) })
        assertEquals(listOf("LauncherDark" to true), calls)
    }
}
