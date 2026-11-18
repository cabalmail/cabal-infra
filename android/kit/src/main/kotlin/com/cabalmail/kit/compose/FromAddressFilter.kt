package com.cabalmail.kit.compose

import com.cabalmail.kit.models.Address

/**
 * What the compose From picker lists for the text typed into its field.
 *
 * Suspended addresses never appear: their DNS is withdrawn, so mail sent
 * from one would draw replies that cannot be delivered. Of the rest, a
 * blank filter keeps every address, and otherwise an address stays when its
 * address or its comment contains the trimmed filter, ignoring case. That
 * is the matching the React and Apple pickers use (React also tries the
 * subdomain, which is part of the address already), so a note written in
 * one client finds its address in every one.
 *
 * Order is kept: the repository already sorts favorites first, then by
 * address, and the picker draws the list as given.
 */
object FromAddressFilter {
    fun apply(
        addresses: List<Address>,
        filter: String,
    ): List<Address> {
        val sendable = addresses.filterNot { it.suspended }
        val needle = filter.trim()
        if (needle.isEmpty()) return sendable
        return sendable.filter {
            it.address.contains(needle, ignoreCase = true) || it.comment.contains(needle, ignoreCase = true)
        }
    }
}
