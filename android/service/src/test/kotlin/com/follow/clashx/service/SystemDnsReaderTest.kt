package com.follow.clashx.service

import org.junit.Assert.assertEquals
import org.junit.Test

class SystemDnsReaderTest {
    @Test fun removesScopedUnroutableAddressesAndBoundsOsInput() {
        assertEquals(listOf("1.1.1.1", "2001:db8::53"), SystemDnsReader.sanitize(listOf(" 1.1.1.1 ", "1.1.1.1", "fe80::53%wlan0", "", "2001:db8::53")))
        assertEquals(16, SystemDnsReader.sanitize((1..30).map { "10.0.0.$it" }).size)
    }
}
