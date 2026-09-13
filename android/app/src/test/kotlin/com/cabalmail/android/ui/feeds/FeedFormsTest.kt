package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOpmlImportFailure
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The management forms' rules, mirroring the Apple `FeedFormsTests`. */
class FeedFormsTest {
    @Test
    fun `feed urls gain https, keep an explicit scheme, and reject junk`() {
        assertEquals("https://example.com/feed", FeedFormRules.normalizedFeedUrl("  example.com/feed "))
        assertEquals("HTTP://example.com/x", FeedFormRules.normalizedFeedUrl("HTTP://example.com/x"))
        assertEquals("https://a.b/c?d=1", FeedFormRules.normalizedFeedUrl("https://a.b/c?d=1"))
        assertNull(FeedFormRules.normalizedFeedUrl(""))
        assertNull(FeedFormRules.normalizedFeedUrl("not a url"))
        assertNull(FeedFormRules.normalizedFeedUrl("localhost"))
    }

    @Test
    fun `folder choices walk the tree and exclude a subtree`() {
        val folders =
            listOf(
                RssFolder("work", name = "Work", displayOrder = 5),
                RssFolder("tech", name = "Tech", displayOrder = 1),
                RssFolder("rust", parentFolderId = "tech", name = "Rust"),
                RssFolder("nightly", parentFolderId = "rust", name = "Nightly"),
            )
        val all = FeedFormRules.folderChoices(folders)
        assertEquals(listOf("Tech", "Rust", "Nightly", "Work"), all.map { it.folder.name })
        assertEquals(listOf(0, 1, 2, 0), all.map { it.depth })
        assertEquals(
            listOf("Tech", "Work"),
            FeedFormRules.folderChoices(folders, excluding = "rust").map { it.folder.name },
        )
    }

    @Test
    fun `the settings update carries only what changed`() {
        val sub = RssSubscription("s1", "f1", customTitle = "Old", folderId = "d1")
        assertNull(
            FeedFormRules.settingsUpdate(
                sub,
                "Old",
                "d1",
                RssOrderingMode.NEWEST_FIRST,
                RssOpenMode.SUMMARY,
                RssStyling.READER,
                RssRemoteContentMode.INHERIT,
            ),
        )
        val update =
            FeedFormRules.settingsUpdate(
                sub,
                "  Mine ",
                "d1",
                RssOrderingMode.NEWEST_FIRST,
                RssOpenMode.ARTICLE,
                RssStyling.READER,
                RssRemoteContentMode.INHERIT,
            )
        assertEquals(RssSubscriptionUpdate(customTitle = "Mine", defaultOpenMode = RssOpenMode.ARTICLE), update)
    }

    @Test
    fun `the folder update detects a rename or a move and needs a name`() {
        val folder = RssFolder("d1", parentFolderId = "p", name = "News")
        assertNull(FeedFormRules.folderUpdate(folder, "News", "p"))
        assertNull(FeedFormRules.folderUpdate(folder, "  ", "q"))
        assertEquals(RssFolderUpdate(parentFolderId = ""), FeedFormRules.folderUpdate(folder, "News", ""))
        assertEquals(
            RssFolderUpdate(name = "Tech", parentFolderId = "q"),
            FeedFormRules.folderUpdate(folder, " Tech ", "q"),
        )
    }

    @Test
    fun `health wording`() {
        val feed = RssFeedSummary("f1")
        assertEquals("Not fetched yet", FeedHealthText.status(feed))
        assertEquals("OK", FeedHealthText.status(feed.copy(lastFetchedAt = "2026-01-01T00:00:00Z")))
        assertEquals(
            "Failing (3 in a row, last status 503)",
            FeedHealthText.status(feed.copy(consecutiveFailureCount = 3, lastStatusCode = 503)),
        )
        assertEquals(
            "Stopped: the fetcher gave up on this feed",
            FeedHealthText.status(feed.copy(deadLettered = true, consecutiveFailureCount = 1)),
        )
        assertEquals("Never", FeedHealthText.lastFetched(feed))
        assertEquals("Not scheduled yet", FeedHealthText.cadence(feed))
        assertEquals("About every 15 minutes", FeedHealthText.cadence(feed.copy(cadenceMinutes = 15)))
        assertEquals("About every hour", FeedHealthText.cadence(feed.copy(cadenceMinutes = 60)))
        assertEquals("About every 2 hours", FeedHealthText.cadence(feed.copy(cadenceMinutes = 150)))
    }

    @Test
    fun `the opml summary counts and lists failures`() {
        assertEquals(
            "2 new feeds, 1 feed already subscribed, 1 folder created.",
            FeedOpmlSummary.text(RssOpmlImportResult(created = 2, existing = 1, foldersCreated = 1)),
        )
        val text =
            FeedOpmlSummary.text(
                RssOpmlImportResult(
                    created = 1,
                    failed =
                        listOf(
                            RssOpmlImportFailure(
                                url = "https://x",
                                code = "not_https",
                                message = "Not served over https",
                            ),
                        ),
                ),
            )
        assertTrue(text.startsWith("1 new feed."))
        assertTrue(text.contains("1 entry could not be added:"))
        assertTrue(text.contains("https://x: Not served over https"))
    }
}
