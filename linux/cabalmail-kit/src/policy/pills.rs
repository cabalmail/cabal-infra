//! What a flag change does to the message list's All / Unread / Flagged
//! counts.
//!
//! The counts come from an IMAP STATUS, which only a server refetch rewrites.
//! Every optimistic path — the row swipe, the reader's toolbar, mark-as-read
//! on open, a bulk action, and the reverts when any of them fail — has to
//! adjust them itself or the pills sit stale until the next refetch. The Apple
//! analog is the counter adjustment `applyOptimisticFlag` makes, whose tests
//! are `MessageListPillCountTests`.
//!
//! The rule is a delta rather than a recount because the list is paged: the
//! rows in hand are a window onto a folder whose totals the client has never
//! seen in full.

/// The IMAP flags the pills count, plus everything else.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flag {
    Seen,
    Flagged,
    Answered,
    /// A custom keyword — the per-message colour slots. Carried on the row,
    /// counted by no pill.
    Keyword,
}

/// How a flag change moves the two counters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Delta {
    pub unseen: i64,
    pub flagged: i64,
}

impl Delta {
    /// Whether this changes anything, which is what decides if the pills need
    /// redrawing at all.
    #[must_use]
    pub fn is_zero(self) -> bool {
        self.unseen == 0 && self.flagged == 0
    }
}

/// The counter change for setting `flag` to `added` on a row that currently
/// `had` it.
///
/// `had` is the guard against double-counting: every one of these paths can
/// fire twice for one change — the reader signals the list, and the list is
/// also the thing that made the request — and a flag that did not actually
/// flip moves no counter. `Seen` is inverted, because the pill counts what is
/// *un*seen.
#[must_use]
pub fn delta(flag: Flag, added: bool, had: bool) -> Delta {
    if added == had {
        return Delta::default();
    }
    let step = if added { 1 } else { -1 };
    match flag {
        Flag::Seen => Delta {
            unseen: -step,
            flagged: 0,
        },
        Flag::Flagged => Delta {
            unseen: 0,
            flagged: step,
        },
        Flag::Answered | Flag::Keyword => Delta::default(),
    }
}

/// Applies a delta to a count, refusing to take it below zero.
///
/// A count that has gone negative is a bug somewhere upstream, but the pill is
/// the wrong place to report it: "-1 unread" is worse than a count that is
/// briefly one short of the truth, and the next refetch corrects either.
#[must_use]
pub fn apply(count: u32, delta: i64) -> u32 {
    let moved = i64::from(count) + delta;
    u32::try_from(moved.max(0)).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reading a message from the reader drops the Unread pill; marking it
    /// unread again puts it back.
    #[test]
    fn reading_and_unreading_move_the_unread_count_the_right_way() {
        assert_eq!(delta(Flag::Seen, true, false).unseen, -1);
        assert_eq!(delta(Flag::Seen, false, true).unseen, 1);
    }

    #[test]
    fn flagging_and_unflagging_move_the_flagged_count() {
        assert_eq!(delta(Flag::Flagged, true, false).flagged, 1);
        assert_eq!(delta(Flag::Flagged, false, true).flagged, -1);
    }

    /// The defect the `had` argument exists for: the reader signals the list
    /// about a change the list had already applied, and the pill counts it
    /// twice.
    #[test]
    fn a_flag_that_did_not_flip_moves_nothing() {
        for flag in [Flag::Seen, Flag::Flagged, Flag::Answered, Flag::Keyword] {
            assert!(delta(flag, true, true).is_zero(), "{flag:?}");
            assert!(delta(flag, false, false).is_zero(), "{flag:?}");
        }
    }

    /// Custom-flag slots ride the same optimistic path but are not what these
    /// pills count.
    #[test]
    fn flags_no_pill_counts_leave_both_alone() {
        for flag in [Flag::Answered, Flag::Keyword] {
            assert!(delta(flag, true, false).is_zero(), "{flag:?}");
            assert!(delta(flag, false, true).is_zero(), "{flag:?}");
        }
    }

    /// Each pill counts one flag. A read that moved the Flagged count would be
    /// a defect nobody would think to look for.
    #[test]
    fn no_flag_change_moves_both_counters() {
        for flag in [Flag::Seen, Flag::Flagged, Flag::Answered, Flag::Keyword] {
            for added in [true, false] {
                let moved = delta(flag, added, !added);
                assert!(
                    moved.unseen == 0 || moved.flagged == 0,
                    "{flag:?} moved both counters"
                );
            }
        }
    }

    /// A failed write reverts the row, and the revert has to take the count
    /// with it — the two deltas have to cancel exactly.
    #[test]
    fn a_revert_undoes_what_the_optimistic_change_did() {
        for flag in [Flag::Seen, Flag::Flagged] {
            let applied = delta(flag, true, false);
            let reverted = delta(flag, false, true);
            assert_eq!(applied.unseen + reverted.unseen, 0, "{flag:?}");
            assert_eq!(applied.flagged + reverted.flagged, 0, "{flag:?}");
        }
    }

    #[test]
    fn a_count_moves_by_its_delta() {
        assert_eq!(apply(3, -1), 2);
        assert_eq!(apply(3, 1), 4);
        assert_eq!(apply(3, 0), 3);
    }

    /// "-1 unread" is worse than a count that is briefly one short.
    #[test]
    fn a_count_never_goes_negative() {
        assert_eq!(apply(0, -1), 0);
        assert_eq!(apply(2, -50), 0);
    }
}
