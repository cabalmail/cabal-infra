//! Stable list identity for message rows.
//!
//! A `GtkListView` model needs each row to keep one identity across a refresh,
//! and an IMAP UID is unique only *within* a folder. A cross-folder search
//! routinely returns the same UID twice — `zeta0803` UID 1 and
//! `alpha0803/kid` UID 1 — and a model handed two items with the same identity
//! draws one of them: the second match is counted by the header and then
//! silently dropped from the list. Keying on UID *plus* Message-ID separates
//! those rows, matching the key [`super::search_source`] uses to route each row
//! back to its own mailbox.
//!
//! The Apple analog is `MessageRowIdentity`.

/// What a row is drawn under.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct RowIdentity {
    pub uid: u32,
    pub message_id: Option<String>,
    /// 0 for the first row with this (uid, message_id) pair, 1 for the next,
    /// and so on.
    ///
    /// The last-resort tiebreak for rows that are indistinguishable even then
    /// — same UID and no Message-ID on either, which the server returns for
    /// envelopes it could not parse. Distinct identities there are still
    /// better than a vanished row; it only means the list rebuilds the later
    /// duplicate when an earlier one is removed.
    pub occurrence: usize,
}

/// Pairs each row with an identity unique across `rows`, preserving order.
///
/// Each row is given as the two fields identity is drawn from, so this can be
/// called with envelopes, search hits, or anything else carrying them.
#[must_use]
pub fn identify<'a, I>(rows: I) -> Vec<RowIdentity>
where
    I: IntoIterator<Item = (u32, Option<&'a str>)>,
{
    let mut seen: std::collections::HashMap<(u32, Option<&str>), usize> =
        std::collections::HashMap::new();
    rows.into_iter()
        .map(|(uid, message_id)| {
            let occurrence = seen.entry((uid, message_id)).or_insert(0);
            let identity = RowIdentity {
                uid,
                message_id: message_id.map(str::to_owned),
                occurrence: *occurrence,
            };
            *occurrence += 1;
            identity
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn identities(rows: &[(u32, Option<&str>)]) -> Vec<RowIdentity> {
        identify(rows.iter().copied())
    }

    /// The defect: a cross-folder search returning one UID twice used to draw
    /// one row while the header counted two.
    #[test]
    fn the_same_uid_in_two_folders_gets_two_identities() {
        let rows = identities(&[
            (1, Some("<a@example.invalid>")),
            (1, Some("<b@example.invalid>")),
        ]);
        assert_ne!(rows[0], rows[1]);
        assert_eq!(rows[0].occurrence, 0);
        assert_eq!(rows[1].occurrence, 0);
    }

    /// One message filed in two folders: same Message-ID, different UIDs.
    #[test]
    fn the_same_message_under_two_uids_gets_two_identities() {
        let rows = identities(&[
            (1, Some("<a@example.invalid>")),
            (7, Some("<a@example.invalid>")),
        ]);
        assert_ne!(rows[0], rows[1]);
    }

    /// Envelopes the server could not parse: same UID, no Message-ID on
    /// either. Nothing tells them apart, so the occurrence counter does.
    #[test]
    fn rows_that_are_otherwise_indistinguishable_are_separated_by_occurrence() {
        let rows = identities(&[(1, None), (1, None), (1, None)]);
        assert_eq!(
            rows.iter().map(|row| row.occurrence).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn every_row_in_a_result_set_keeps_its_own_identity() {
        let rows = identities(&[
            (1, Some("<a@example.invalid>")),
            (1, Some("<a@example.invalid>")),
            (1, None),
            (1, None),
            (2, Some("<a@example.invalid>")),
        ]);
        let distinct: HashSet<&RowIdentity> = rows.iter().collect();
        assert_eq!(distinct.len(), rows.len(), "{rows:?}");
    }

    #[test]
    fn order_is_the_order_the_server_returned() {
        let rows = identities(&[(3, None), (1, None), (2, None)]);
        assert_eq!(
            rows.iter().map(|row| row.uid).collect::<Vec<_>>(),
            vec![3, 1, 2]
        );
    }

    #[test]
    fn an_empty_result_set_identifies_nothing() {
        assert!(identities(&[]).is_empty());
    }
}
