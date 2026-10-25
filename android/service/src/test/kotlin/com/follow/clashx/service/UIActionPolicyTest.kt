package com.follow.clashx.service

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UIActionPolicyTest {
    @Test fun frontendHelpersCanReadAndValidateThroughTheExistingBridge() {
        for (method in listOf("backend", "probe", "outboundIp", "serviceCheck", "watchRoute",
            "getConnectionCount", "getMemoryStats", "encodeShareLinks", "decodeShareLinks",
            "validateFilters", "validateProxies", "getProxiesData", "setHostActive")) {
            assertTrue(UIActionPolicy.allows(method), method)
        }
    }

    @Test fun helpersCannotBypassTheCoordinatorOrOpenASecondBackend() {
        for (method in listOf("", "initClash", "start", "stop", "restart", "startListener", "stopListener",
            "startTun", "stopTun", "setupConfig", "updateConfig", "changeProxy", "updateDNS",
            "resetNetwork", "backend.open", "backend.host.event", "backend.platform.complete",
            "validateConfig", "getConfig", "buildProfile")) {
            assertFalse(UIActionPolicy.allows(method), method)
        }
    }
}
