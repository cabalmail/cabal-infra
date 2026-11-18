package com.cabalmail.kit.compose

import com.cabalmail.kit.models.Address
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class FromAddressFilterTest {
    private val alerts = Address(address = "alerts@bank.example.com", subdomain = "bank", favorite = true)
    private val work =
        Address(address = "work@acme.example.com", subdomain = "acme", comment = "Day job", favorite = true)
    private val daily = Address(address = "daily@qa0722.cabal-mail.com", subdomain = "qa0722")
    private val shop = Address(address = "shop@store.example.com", subdomain = "store", comment = "Groceries")
    private val old =
        Address(address = "old@gone.example.com", subdomain = "gone", comment = "Groceries", suspended = true)

    // The repository's order: favorites first, then by address.
    private val addresses = listOf(alerts, work, daily, old, shop)

    @Test
    fun `a blank filter keeps every sendable address in the given order`() {
        assertEquals(listOf(alerts, work, daily, shop), FromAddressFilter.apply(addresses, ""))
        assertEquals(listOf(alerts, work, daily, shop), FromAddressFilter.apply(addresses, "   "))
    }

    @Test
    fun `the filter matches any part of the address in any case`() {
        assertEquals(listOf(shop), FromAddressFilter.apply(addresses, "STORE"))
        assertEquals(listOf(daily), FromAddressFilter.apply(addresses, "ail"))
        assertEquals(listOf(daily), FromAddressFilter.apply(addresses, " daily@qa "))
        assertEquals(listOf(alerts, work, shop), FromAddressFilter.apply(addresses, "example.com"))
    }

    @Test
    fun `the filter matches the comment`() {
        assertEquals(listOf(shop), FromAddressFilter.apply(addresses, "groc"))
        assertEquals(listOf(work), FromAddressFilter.apply(addresses, "day job"))
    }

    @Test
    fun `a suspended address never matches, even on its own name`() {
        assertTrue(FromAddressFilter.apply(addresses, "old@gone").isEmpty())
    }

    @Test
    fun `a filter that matches nothing is empty`() {
        assertTrue(FromAddressFilter.apply(addresses, "zzz").isEmpty())
        assertTrue(FromAddressFilter.apply(emptyList(), "").isEmpty())
    }
}
