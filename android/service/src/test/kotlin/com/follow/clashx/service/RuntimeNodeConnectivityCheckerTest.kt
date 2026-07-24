package com.follow.clashx.service

import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

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

    @Test
    fun buildsAQueryForTheHost() {
        val (id, query) = RuntimeNodeConnectivityChecker.buildDnsQuery("youtube.com")
        // Header: id, RD=1, QDCOUNT=1, everything else zero.
        assertEquals(id ushr 8, query[0].toInt() and 0xff)
        assertEquals(id and 0xff, query[1].toInt() and 0xff)
        assertContentEquals(
            byteArrayOf(0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
            query.copyOfRange(2, 12),
        )
        // QNAME + QTYPE=A + QCLASS=IN.
        assertContentEquals(
            byteArrayOf(
                0x07, *"youtube".encodeToByteArray(),
                0x03, *"com".encodeToByteArray(),
                0x00,
                0x00, 0x01,
                0x00, 0x01,
            ),
            query.copyOfRange(12, query.size),
        )
    }

    @Test
    fun parsesCompressedAnswerAddress() {
        val response = byteArrayOf(
            0x12, 0x34, // id
            0x81.toByte(), 0x80.toByte(), // flags: QR=1, RD=1, RA=1, RCODE=0
            0x00, 0x01, // QDCOUNT
            0x00, 0x01, // ANCOUNT
            0x00, 0x00, // NSCOUNT
            0x00, 0x00, // ARCOUNT
            // Question: youtube.com A IN
            0x07, *"youtube".encodeToByteArray(),
            0x03, *"com".encodeToByteArray(),
            0x00,
            0x00, 0x01,
            0x00, 0x01,
            // Answer: name is a compression pointer to offset 12
            0xc0.toByte(), 0x0c,
            0x00, 0x01, // TYPE=A
            0x00, 0x01, // CLASS=IN
            0x00, 0x00, 0x01, 0x00, // TTL
            0x00, 0x04, // RDLENGTH
            142.toByte(), 250.toByte(), 72, 14, // RDATA
        )

        val addresses = RuntimeNodeConnectivityChecker.parseDnsAnswers(response, 0x1234)

        assertContentEquals(
            listOf(InetAddress.getByName("142.250.72.14")),
            addresses,
        )
    }

    @Test
    fun ignoresAnswersWithAMismatchedTransactionId() {
        val response = byteArrayOf(
            0x12, 0x34,
            0x81.toByte(), 0x80.toByte(),
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        )

        assertTrue(RuntimeNodeConnectivityChecker.parseDnsAnswers(response, 0x9999).isEmpty())
    }

    @Test
    fun ignoresRecordsOutsideTheInternetClass() {
        val response = byteArrayOf(
            0x12, 0x34,
            0x81.toByte(), 0x80.toByte(),
            0x00, 0x01, // QDCOUNT
            0x00, 0x01, // ANCOUNT
            0x00, 0x00,
            0x00, 0x00,
            0x07, *"youtube".encodeToByteArray(),
            0x03, *"com".encodeToByteArray(),
            0x00,
            0x00, 0x01,
            0x00, 0x01,
            0xc0.toByte(), 0x0c,
            0x00, 0x01, // TYPE=A
            0x00, 0x03, // CLASS=CH, not IN
            0x00, 0x00, 0x01, 0x00,
            0x00, 0x04,
            142.toByte(), 250.toByte(), 72, 14,
        )

        assertTrue(RuntimeNodeConnectivityChecker.parseDnsAnswers(response, 0x1234).isEmpty())
    }
}
