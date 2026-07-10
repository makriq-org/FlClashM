package com.follow.clashx.common

object Components {
    const val PACKAGE_NAME = "com.follow.clashx"

    // The applicationId (com.makriq.flclash) differs from the Kotlin package,
    // so anything that needs the RUNTIME package (setClassName, permissions)
    // must use this instead of PACKAGE_NAME.
    val runtimePackageName: String
        get() = GlobalState.application.packageName
}
