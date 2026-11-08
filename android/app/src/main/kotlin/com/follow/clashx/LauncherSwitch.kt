package com.follow.clashx

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
