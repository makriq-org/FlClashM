package com.follow.clashx

/** Retry delay is bounded; a user action starts a fresh sequence immediately. */
internal class LauncherRetry {
    private var delay = 2000L

    fun nextDelayMillis(): Long {
        val current = delay
        delay = (delay * 2).coerceAtMost(60_000L)
        return current
    }

    fun reset() { delay = 2000L }
}

/** Platform-independent switching contract. Null task state must fail closed. */
internal object LauncherSwitch {
    fun apply(
        selected: String,
        names: List<String>,
        active: Set<String>?,
        setEnabled: (String, Boolean) -> Unit,
    ): Boolean {
        // Failure to enable a replacement must leave every old entry untouched.
        try { setEnabled(selected, true) } catch (_: RuntimeException) { return true }
        var pending = false
        for (name in names.filter { it != selected }) {
            if (active == null || name in active) {
                pending = true
                continue
            }
            try { setEnabled(name, false) } catch (_: RuntimeException) { pending = true }
        }
        return pending
    }
}

/** Launcher resource resolution may use a day configuration even in night mode. */
internal fun launcherPalette(dark: Boolean, pureBlack: Boolean): String = when {
    !dark -> "LauncherLight"
    pureBlack -> "LauncherBlack"
    else -> "LauncherDark"
}
