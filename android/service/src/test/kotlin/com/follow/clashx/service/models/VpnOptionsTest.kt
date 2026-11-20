package com.follow.clashx.service.models

import com.follow.clashx.common.AccessControlMode
import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnOptionsTest {
    @Test
    fun `missing access control fields fall back to defaults`() {
        val options = Gson()
            .fromJson(
                """{"accessControl":{"acceptList":null,"rejectList":["com.example"]}}""",
                VpnOptions::class.java,
            )
            .gsonSanitized()

        val access = options.accessControl!!
        assertEquals(AccessControlMode.rejectSelected, access.mode)
        assertTrue(access.acceptList.isEmpty())
        assertEquals(listOf("com.example"), access.rejectList)
    }

    @Test
    fun `an explicit access control mode is kept`() {
        val options = Gson()
            .fromJson(
                """{"accessControl":{"mode":"acceptSelected","acceptList":[],"rejectList":[]}}""",
                VpnOptions::class.java,
            )
            .gsonSanitized()

        assertEquals(AccessControlMode.acceptSelected, options.accessControl!!.mode)
    }
}
