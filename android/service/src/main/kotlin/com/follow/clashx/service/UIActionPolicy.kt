package com.follow.clashx.service

/** Legacy envelope compatibility, not a second runtime API. Durable writes and
 * runtime intent go through `backend` (Go API v1 / RuntimeCoordinator). Helpers
 * only observe the engine, validate input or manage a UI observer subscription.
 * In particular validateProxies delegates to the isolated :validator in Go. */
internal object UIActionPolicy {
    private val allowed = setOf(
        "backend", "getIsInit", "forceGc", "getProxies", "getTraffic", "getTotalTraffic",
        "asyncTestDelay", "getConnections", "getExternalProviders", "getExternalProvider",
        "getCountryCode", "getMemory", "getCoreVersion", "healthCheck", "healthProbe",
        "setUiActive", "startLog", "stopLog", "tunnelHTTPRequest", "cancelTunnelHTTPRequest",
        "getRuntimeSnapshot", "getAndroidVpnOptions", "getRunTime", "getCurrentProfileName",
        "probe", "outboundIp", "serviceCheck", "watchRoute", "getConnectionCount",
        "getMemoryStats", "encodeShareLinks", "decodeShareLinks", "validateFilters",
        "validateProxies", "getProxiesData", "setHostActive",
    )

    fun allows(method: String): Boolean = method in allowed
}
