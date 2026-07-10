package com.follow.clashx.common

enum class BroadcastAction(val action: String) {
    SERVICE_CREATED("${Components.PACKAGE_NAME}.intent.action.SERVICE_CREATED"),
    SERVICE_DESTROYED("${Components.PACKAGE_NAME}.intent.action.SERVICE_DESTROYED"),
}

enum class AccessControlMode {
    acceptSelected,
    rejectSelected,
}
