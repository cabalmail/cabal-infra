//! Which mailbox owns each row of a cross-folder search result.
//!
//! IMAP UIDs are unique only *within* a folder, so a result set spanning
//! folders routinely carries the same UID twice — Archive UID 1 and
//! `zeta0802` UID 1. A plain UID-to-folder map is therefore lossy, and in
//! Swift, built with `Dictionary(uniqueKeysWithValues:)`, it was fatal. The
//! index keys on UID *plus* Message-ID, which separates same-UID rows in
//! different folders while still separating the other collision shape: one
//! message filed in two folders, same Message-ID under two different UIDs.
//!
//! A row whose envelope has no Message-ID falls back to the UID-only map,
//! which keeps the first row seen for that UID — a best-effort answer rather
//! than none.
//!
//! The Apple analog is `SearchSourceFolderIndex`. It keys on the same pair
//! [`super::row_identity`] draws rows under, which is what makes a row's
//! identity and its source folder answer to one lookup.

use std::collections::HashMap;

/// The folder each row of a result set came from.
///
/// Empty for folder mode and single-folder searches, where the model's own
/// folder is the answer and there is nothing to look up.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceFolderIndex {
    by_row: HashMap<(u32, Option<String>), String>,
    by_uid: HashMap<u32, String>,
}

impl SourceFolderIndex {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.by_row.is_empty()
    }

    /// Extends the index with a page of results.
    ///
    /// First-wins on both maps, including across pages: a duplicate is a
    /// genuine ambiguity — two rows the index cannot tell apart — and the first
    /// match in server order is the row the user sees highest.
    pub fn add<'a, I>(&mut self, rows: I)
    where
        I: IntoIterator<Item = (u32, Option<&'a str>, &'a str)>,
    {
        for (uid, message_id, folder) in rows {
            self.by_row
                .entry((uid, message_id.map(str::to_owned)))
                .or_insert_with(|| folder.to_owned());
            self.by_uid.entry(uid).or_insert_with(|| folder.to_owned());
        }
    }

    /// The folder a row came from, or `None` when this index does not know it
    /// — folder mode, or a row that was never part of the result set.
    #[must_use]
    pub fn folder(&self, uid: u32, message_id: Option<&str>) -> Option<&str> {
        self.by_row
            .get(&(uid, message_id.map(str::to_owned)))
            .or_else(|| self.by_uid.get(&uid))
            .map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(rows: &[(u32, Option<&str>, &str)]) -> SourceFolderIndex {
        let mut built = SourceFolderIndex::new();
        built.add(rows.iter().copied());
        built
    }

    #[test]
    fn an_empty_index_knows_nothing() {
        let built = SourceFolderIndex::new();
        assert!(built.is_empty());
        assert_eq!(built.folder(1, None), None);
    }

    /// The collision the index exists for: one UID in two folders.
    #[test]
    fn the_same_uid_in_two_folders_routes_to_both() {
        let built = index(&[
            (1, Some("<a@example.invalid>"), "Archive"),
            (1, Some("<b@example.invalid>"), "zeta0802"),
        ]);
        assert_eq!(
            built.folder(1, Some("<a@example.invalid>")),
            Some("Archive")
        );
        assert_eq!(
            built.folder(1, Some("<b@example.invalid>")),
            Some("zeta0802")
        );
    }

    /// The other collision shape: one message filed twice, same Message-ID
    /// under two UIDs.
    #[test]
    fn one_message_under_two_uids_routes_to_both() {
        let built = index(&[
            (1, Some("<a@example.invalid>"), "Archive"),
            (7, Some("<a@example.invalid>"), "zeta0802"),
        ]);
        assert_eq!(
            built.folder(1, Some("<a@example.invalid>")),
            Some("Archive")
        );
        assert_eq!(
            built.folder(7, Some("<a@example.invalid>")),
            Some("zeta0802")
        );
    }

    /// A row the server returned without a Message-ID still gets an answer,
    /// from the UID map.
    #[test]
    fn a_row_with_no_message_id_falls_back_to_the_uid() {
        let built = index(&[(4, None, "Archive")]);
        assert_eq!(built.folder(4, None), Some("Archive"));
    }

    /// A lookup for a row whose Message-ID was never indexed still resolves
    /// through the UID map rather than returning nothing.
    #[test]
    fn an_unindexed_message_id_falls_back_to_the_uid() {
        let built = index(&[(4, Some("<a@example.invalid>"), "Archive")]);
        assert_eq!(
            built.folder(4, Some("<z@example.invalid>")),
            Some("Archive")
        );
    }

    #[test]
    fn a_row_that_was_never_in_the_result_set_is_unknown() {
        let built = index(&[(4, None, "Archive")]);
        assert_eq!(built.folder(5, None), None);
    }

    /// First in server order is the row the user sees highest, so it is the
    /// one an ambiguous lookup answers with.
    #[test]
    fn a_duplicate_keeps_the_row_the_user_sees_first() {
        let built = index(&[(1, None, "Archive"), (1, None, "zeta0802")]);
        assert_eq!(built.folder(1, None), Some("Archive"));
    }

    /// Later pages extend the index without displacing what an earlier page
    /// established.
    #[test]
    fn a_later_page_does_not_displace_an_earlier_one() {
        let mut built = index(&[(1, Some("<a@example.invalid>"), "Archive")]);
        built.add([
            (1, Some("<a@example.invalid>"), "zeta0802"),
            (2, Some("<b@example.invalid>"), "zeta0802"),
        ]);
        assert_eq!(
            built.folder(1, Some("<a@example.invalid>")),
            Some("Archive")
        );
        assert_eq!(
            built.folder(2, Some("<b@example.invalid>")),
            Some("zeta0802")
        );
    }
}
