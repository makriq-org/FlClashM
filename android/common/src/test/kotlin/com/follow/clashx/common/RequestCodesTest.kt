package com.follow.clashx.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RequestCodesTest {
    @Test
    fun `the answer to a replaced launch does not answer the newer one`() {
        val codes = RequestCodes(first = 1100, count = 64)
        val replaced = codes.issue()!!
        val latest = codes.issue()!!

        assertFalse(codes.answers(replaced))
        assertTrue(codes.answers(latest))
        assertFalse(codes.answers(latest))
    }

    @Test
    fun `answered codes stay in their range and wrap around`() {
        val codes = RequestCodes(first = 10, count = 2)

        val issued = List(3) { codes.issue()!!.also(codes::answers) }

        assertEquals(listOf(10, 11, 10), issued)
        assertTrue(10 in codes)
        assertFalse(12 in codes)
        assertFalse(9 in codes)
    }

    @Test
    fun `a replaced launch keeps its code until it answers or the activity is gone`() {
        val codes = RequestCodes(first = 10, count = 2)
        val replaced = codes.issue()!!
        val latest = codes.issue()!!

        assertTrue(codes.answers(latest))
        // The replaced launch may still answer late, so its code stays taken
        // and the answered one is handed out again instead.
        assertEquals(latest, codes.issue())
        assertFalse(codes.answers(replaced))
    }

    @Test
    fun `a stale answer frees its own code without answering the newer launch`() {
        val codes = RequestCodes(first = 10, count = 2)
        val replaced = codes.issue()!!
        val latest = codes.issue()!!

        // The stale answer settles nothing and frees only the code it belongs to.
        assertFalse(codes.answers(replaced))
        assertTrue(codes.answers(latest))
        // A newer launch then takes the freed code and answers it itself.
        val reused = codes.issue()!!
        assertEquals(replaced, reused)
        assertTrue(codes.answers(reused))
    }

    @Test
    fun `no code is handed out while every one still waits for its answer`() {
        val codes = RequestCodes(first = 10, count = 2)
        val first = codes.issue()
        codes.issue()

        assertNull(codes.issue())
        codes.answers(first!!)
        assertEquals(first, codes.issue())
    }

    @Test
    fun `a reset frees the codes an activity that is gone can no longer answer`() {
        val codes = RequestCodes(first = 10, count = 2)
        codes.issue()
        codes.issue()

        codes.reset()

        assertEquals(10, codes.issue())
    }

    @Test
    fun `an issued code is recognised and an unrelated one is not`() {
        val codes = RequestCodes(first = 1100, count = 64)
        codes.issue()

        assertTrue(1100 in codes)
        assertFalse(1164 in codes)
        assertFalse(1099 in codes)
    }
}
