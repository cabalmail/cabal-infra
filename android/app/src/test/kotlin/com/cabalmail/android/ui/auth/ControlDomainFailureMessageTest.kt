package com.cabalmail.android.ui.auth

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.io.IOException
import java.net.ConnectException
import java.net.UnknownHostException

class ControlDomainFailureMessageTest {
    @Test
    fun `a DNS miss names the host and the expected shape`() {
        val message = controlDomainFailureMessage("admin.example.org", UnknownHostException("admin.example.org"))
        assertEquals(
            "No such host: admin.example.org — check the control domain (it looks like admin.example.com)",
            message,
        )
    }

    @Test
    fun `a wrapped DNS miss is still recognised`() {
        val wrapped = IOException("retry exhausted", UnknownHostException("admin.example.org"))
        val message = controlDomainFailureMessage("admin.example.org", wrapped)
        assertEquals(
            "No such host: admin.example.org — check the control domain (it looks like admin.example.com)",
            message,
        )
    }

    @Test
    fun `other transport failures keep the generic wording`() {
        val message = controlDomainFailureMessage("admin.example.org", ConnectException("refused"))
        assertEquals(
            "Couldn't reach admin.example.org — check the control domain and your connection",
            message,
        )
    }
}
