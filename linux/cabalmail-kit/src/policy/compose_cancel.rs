//! What closing a compose window without sending does with the buffer.
//!
//! The Apple analog is `ComposeCancelPolicy`, split out of its view model
//! because the decision is an *ordering* — and getting that order wrong is how
//! "Save Draft" came to throw a draft away (issue #903). The same three
//! preconditions apply here, and the same order.

/// What Cancel resolves to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The editor bridge is dead, so every body converts to `""`. Keep the
    /// local autosave, push nothing to the server, let the window go.
    CloseKeepingLocalCopy,
    /// Nothing worth keeping: drop any server copy and the local one.
    DiscardEmpty,
    /// There is content but no sender to save it under. Refuse and stay in the
    /// composer so a From address can be picked, or the draft discarded.
    RefuseMissingFrom,
    /// Push the buffer to the Drafts folder, then close.
    SaveToServer,
}

/// Banner text for a save refused because no From address is selected.
///
/// `/save_draft` has no envelope to authorize against without one, so there is
/// nothing to do but ask — closing silently loses whatever was typed, which is
/// the defect this replaces.
pub const MISSING_FROM_MESSAGE: &str = "Couldn't save draft: pick a From address first. Everything you typed is still here — \
     choose an address and save again, or use Discard Draft to throw it away.";

/// One button of the confirmation dialog Cancel raises, in the order the
/// dialog offers them.
///
/// A type rather than three buttons written inline, because the set — and
/// which member the dialog dismisses to — is the part worth testing. On Apple
/// that role was load-bearing in a way nobody predicted: SwiftUI drops the
/// cancel-role button when the dialog renders as a popover and runs its action
/// on an outside tap, so with "Save Draft" holding the role an accidental tap
/// silently closed the composer. `AdwAlertDialog` has the same hazard by a
/// different route — `set_close_response` names what Escape and a click
/// outside resolve to, and the default is the first response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    Discard,
    SaveDraft,
    KeepEditing,
}

impl Choice {
    /// The buttons, in the order the dialog packs them.
    pub const ORDER: &'static [Choice] = &[Choice::Discard, Choice::SaveDraft, Choice::KeepEditing];

    /// The button's label.
    #[must_use]
    pub fn title(self) -> &'static str {
        match self {
            Self::Discard => "Discard Draft",
            Self::SaveDraft => "Save Draft",
            Self::KeepEditing => "Keep Editing",
        }
    }

    /// The `AdwAlertDialog` response id this button is added under.
    #[must_use]
    pub fn id(self) -> &'static str {
        match self {
            Self::Discard => "discard",
            Self::SaveDraft => "save-draft",
            Self::KeepEditing => "keep-editing",
        }
    }

    /// Whether the button destroys something, which is what paints it red.
    #[must_use]
    pub fn is_destructive(self) -> bool {
        self == Self::Discard
    }

    /// Whether closing the dialog without choosing loses anything.
    #[must_use]
    pub fn loses_the_draft(self) -> bool {
        self == Self::Discard
    }
}

/// What Escape, and a click outside the dialog, resolve to.
///
/// It has to be the button that does nothing. Every other answer means a
/// stray keypress or a misplaced click throws away what was typed, which is
/// the defect the Apple client shipped and then had to fix.
#[must_use]
pub fn close_response() -> Choice {
    Choice::KeepEditing
}

/// The decision behind Cancel → "Save Draft".
///
/// The order is the rule. A dead bridge wins over everything: there is no body
/// to push and the local copy is already flushed. An empty compose is next, so
/// opening and closing a composer without a From leaves no breadcrumb. Only
/// then does a missing sender matter — checking it any earlier is what turned
/// "Save Draft" on a half-filled message into a silent discard.
#[must_use]
pub fn resolve(bridge_failed: bool, has_content: bool, has_from: bool) -> Resolution {
    if bridge_failed {
        return Resolution::CloseKeepingLocalCopy;
    }
    if !has_content {
        return Resolution::DiscardEmpty;
    }
    if !has_from {
        return Resolution::RefuseMissingFrom;
    }
    Resolution::SaveToServer
}

/// Whether Cancel has anything to ask about.
///
/// The three-way dialog — keep the draft, discard it, go back to editing — is
/// a real question only when there is a draft to keep. Over an untouched
/// composer every answer lands on [`Resolution::DiscardEmpty`], which throws
/// away nothing, so asking is a decision that cannot be got wrong and cannot
/// be avoided.
///
/// A dead bridge counts as something to ask about even though the buffer reads
/// as empty: the body converted to `""` because the editor is broken, not
/// because nothing was typed, and the answer decides whether the local copy
/// survives. Guessing "empty" there silently drops text the user cannot see we
/// have.
#[must_use]
pub fn needs_decision(bridge_failed: bool, has_content: bool) -> bool {
    bridge_failed || has_content
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filled_compose_with_a_sender_is_saved() {
        assert_eq!(resolve(false, true, true), Resolution::SaveToServer);
    }

    #[test]
    fn an_untouched_compose_leaves_nothing_behind() {
        assert_eq!(resolve(false, false, true), Resolution::DiscardEmpty);
        assert_eq!(resolve(false, false, false), Resolution::DiscardEmpty);
    }

    /// The defect the ordering exists for: checking the sender before the
    /// content turned Save Draft on a half-filled message into a discard.
    #[test]
    fn content_without_a_sender_refuses_rather_than_discarding() {
        assert_eq!(resolve(false, true, false), Resolution::RefuseMissingFrom);
    }

    /// A dead bridge reports every body as empty, so it has to be read before
    /// the emptiness test or the local copy goes with the window.
    #[test]
    fn a_dead_bridge_beats_every_other_precondition() {
        for has_content in [true, false] {
            for has_from in [true, false] {
                assert_eq!(
                    resolve(true, has_content, has_from),
                    Resolution::CloseKeepingLocalCopy,
                    "bridge_failed lost to ({has_content}, {has_from})"
                );
            }
        }
    }

    #[test]
    fn an_untouched_compose_is_closed_without_a_question() {
        assert!(!needs_decision(false, false));
    }

    #[test]
    fn there_is_something_to_ask_about_whenever_something_could_be_lost() {
        assert!(needs_decision(false, true));
        assert!(needs_decision(true, false));
        assert!(needs_decision(true, true));
    }

    /// Every case the dialog is skipped for has to be one where the answer
    /// could not have changed the outcome.
    #[test]
    fn nothing_is_thrown_away_by_a_question_that_was_not_asked() {
        for has_from in [true, false] {
            assert_eq!(resolve(false, false, has_from), Resolution::DiscardEmpty);
        }
    }

    /// The whole reason the choice is a type: dismissing the dialog must not
    /// be a way to lose the draft. Escape and a click outside both land on the
    /// close response, and neither is a deliberate answer to the question.
    #[test]
    fn dismissing_the_dialog_cannot_lose_the_draft() {
        assert!(!close_response().loses_the_draft());
        assert!(!close_response().is_destructive());
    }

    /// `AdwAlertDialog` defaults its close response to the first one added, so
    /// the button that does nothing must not be the one the dialog leads with
    /// — a dialog that forgot to call `set_close_response` would then dismiss
    /// to Discard.
    #[test]
    fn the_close_response_is_not_the_one_the_dialog_leads_with() {
        assert_ne!(Choice::ORDER[0], close_response());
    }

    #[test]
    fn the_dialog_offers_every_choice_once() {
        for choice in [Choice::Discard, Choice::SaveDraft, Choice::KeepEditing] {
            assert_eq!(
                Choice::ORDER
                    .iter()
                    .filter(|other| **other == choice)
                    .count(),
                1,
                "{choice:?} is offered {:?} times",
                Choice::ORDER
            );
        }
    }

    /// Only the discard is destructive, and the response ids are distinct —
    /// two buttons sharing one id would make the dialog unanswerable.
    #[test]
    fn each_button_is_distinct_and_only_one_destroys_anything() {
        let ids: Vec<&str> = Choice::ORDER.iter().map(|choice| choice.id()).collect();
        for choice in Choice::ORDER {
            assert_eq!(ids.iter().filter(|id| **id == choice.id()).count(), 1);
            assert!(!choice.title().is_empty());
            assert_eq!(choice.is_destructive(), *choice == Choice::Discard);
        }
    }

    /// The dialog is only raised when there is something to ask about, and
    /// every choice it offers has to be an answer to that question.
    #[test]
    fn the_dialog_is_only_offered_when_there_is_a_draft_to_keep() {
        assert!(needs_decision(false, true));
        assert_eq!(resolve(false, true, true), Resolution::SaveToServer);
        assert!(Choice::ORDER.contains(&Choice::SaveDraft));
    }

    /// The banner is the only thing standing between a refused save and a user
    /// who thinks it worked, so it has to say what to do next.
    #[test]
    fn the_refusal_says_the_text_is_safe_and_what_to_do() {
        assert!(MISSING_FROM_MESSAGE.contains("still here"));
        assert!(MISSING_FROM_MESSAGE.contains("From address"));
        assert!(MISSING_FROM_MESSAGE.contains("Discard Draft"));
    }
}
