package com.follow.clashx.service

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith

class RuntimeNodeConnectivityCheckerTest {
    @Test
    fun sendsDomainTargetsWithoutLocalResolution() {
        assertContentEquals(
            byteArrayOf(
                0x05,
                0x01,
                0x00,
                0x03,
                0x0b,
                *"youtube.com".encodeToByteArray(),
                0x01,
                0xbb.toByte(),
            ),
            RuntimeNodeConnectivityChecker.buildSocksConnectRequest(
                "youtube.com",
                443,
            ),
        )
    }

    @Test
    fun keepsPublicIpLiteralSupport() {
        assertContentEquals(
            byteArrayOf(
                0x05,
                0x01,
                0x00,
                0x01,
                0x01,
                0x01,
                0x01,
                0x01,
                0x00,
                0x50,
            ),
            RuntimeNodeConnectivityChecker.buildSocksConnectRequest(
                "1.1.1.1",
                80,
            ),
        )
    }

    @Test
    fun rejectsPrivateIpLiterals() {
        assertFailsWith<IllegalArgumentException> {
            RuntimeNodeConnectivityChecker.buildSocksConnectRequest(
                "127.0.0.1",
                443,
            )
        }
    }
}
