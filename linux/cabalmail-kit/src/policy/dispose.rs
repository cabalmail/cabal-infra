//! What a dispose-family affordance actually does in the folder on screen.
//!
//! Every dispose surface — the row's trailing swipe, the reader's toolbar
//! button, the row and selection context menus, the bulk action bar,
//! Ctrl+Delete — starts from a requested destination and then has to reconcile
//! it with where the user already is. Two folders are their own destination:
//!
//! - In **Trash**, "move to Trash" is meaningless, so a delete means gone
//!   forever and stages a confirmation.
//! - In **Archive**, "move to Archive" is a same-folder move: the server
//!   honours it, hands the message a fresh UID, and the client prunes the row
//!   for a message that never left. So the archive affordance becomes Restore,
//!   which puts the message back in the inbox.
//!
//! The Apple analog is `DisposeIntent`. The rule lives here, as a pure
//! function of (request, folder), so the labels the views draw and the
//! operations they run come from one decision rather than a `folder ==` test
//! repeated at each surface.

/// The folders that are their own destination, spelled as the API's folder
/// paths.
pub const INBOX: &str = "INBOX";
pub const ARCHIVE: &str = "Archive";
pub const TRASH: &str = "Trash";

/// Where the default dispose affordance files a message. The user's
/// `dispose_action` preference.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Archive,
    Trash,
}

impl Action {
    /// The preference's spelling in `config.toml` and in the server's `app`
    /// map.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Archive => "archive",
            Self::Trash => "trash",
        }
    }

    /// The preference as read from the configuration store. `None` for a
    /// spelling the schema does not accept, which it rejects long before this.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "archive" => Some(Self::Archive),
            "trash" => Some(Self::Trash),
            _ => None,
        }
    }

    fn destination(self) -> &'static str {
        match self {
            Self::Archive => ARCHIVE,
            Self::Trash => TRASH,
        }
    }
}

/// What a dispose affordance does here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Intent {
    /// File the message into Archive or Trash — the ordinary case.
    Move(Action),
    /// Undo the archive: move back to the inbox. Only inside Archive.
    Restore,
    /// Permanent delete, behind a confirmation. Only inside Trash.
    Purge,
}

impl Intent {
    /// Where a move-shaped intent sends the message. `None` for [`Self::Purge`],
    /// which moves nothing.
    #[must_use]
    pub fn destination_folder(self) -> Option<&'static str> {
        match self {
            Self::Move(action) => Some(action.destination()),
            Self::Restore => Some(INBOX),
            Self::Purge => None,
        }
    }

    /// Whether this destroys anything that cannot be got back — what drives
    /// the destructive button style and the red swipe tint. Restore is a plain
    /// move back to the inbox, so it reads as neither.
    #[must_use]
    pub fn is_destructive(self) -> bool {
        match self {
            Self::Move(action) => action == Action::Trash,
            Self::Restore => false,
            Self::Purge => true,
        }
    }

    /// Whether this has to be confirmed before it runs.
    #[must_use]
    pub fn needs_confirmation(self) -> bool {
        self == Self::Purge
    }
}

/// Which leg of the two-stage row-disposal animation a row is in. Settled rows
/// have no phase at all.
///
/// Fade first, collapse second, deliberately sequential: the row goes
/// transparent at full height, so nothing moves and the eye catches the
/// change, and only then does the gap close. Removing the row outright reads
/// as though nothing happened — under a list that addresses rows by index it
/// is not even a removal, just every slot below re-pointing at the next
/// message — which invites a second swipe on whatever slid into the vacated
/// position.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DisposalPhase {
    /// Full height, fading to transparent. Nothing moves yet.
    Fading,
    /// Transparent, collapsing to zero height. This is the leg that closes the
    /// gap and shifts the rows below up.
    Collapsing,
}

/// How long each leg lasts. Fast enough not to slow triage down, long enough
/// for the eye to register that something left the list.
pub const FADE: std::time::Duration = std::time::Duration::from_millis(150);
pub const COLLAPSE: std::time::Duration = std::time::Duration::from_millis(150);

impl DisposalPhase {
    /// The leg that follows this one, or `None` when the row is gone.
    #[must_use]
    pub fn next(self) -> Option<Self> {
        match self {
            Self::Fading => Some(Self::Collapsing),
            Self::Collapsing => None,
        }
    }

    /// How long this leg runs for.
    #[must_use]
    pub fn duration(self) -> std::time::Duration {
        match self {
            Self::Fading => FADE,
            Self::Collapsing => COLLAPSE,
        }
    }
}

/// How long the whole animation takes — how long the message has to be kept in
/// the list after the write, so the row it is drawn from outlives the
/// animation.
#[must_use]
pub fn disposal_duration() -> std::time::Duration {
    FADE + COLLAPSE
}

/// The intent behind the *default* dispose affordance — the trailing swipe,
/// the reader's toolbar button, Ctrl+Delete — which follows the user's
/// preference.
///
/// Trash is checked before the preference: inside Trash the affordance is
/// Delete Forever whichever way the preference points.
#[must_use]
pub fn standard(preference: Action, folder_path: &str) -> Intent {
    if folder_path == TRASH {
        return Intent::Purge;
    }
    if folder_path == ARCHIVE && preference == Action::Archive {
        return Intent::Restore;
    }
    Intent::Move(preference)
}

/// The intent behind an *explicitly* Archive affordance — the context menus'
/// Archive item, the bulk bar's Archive button, and the reader menu's
/// alternate destination when the preference points at Trash.
///
/// Inside Trash this stays a real archive: it is the rescue path out of the
/// deleted pile, not a same-folder move.
#[must_use]
pub fn archiving(folder_path: &str) -> Intent {
    if folder_path == ARCHIVE {
        Intent::Restore
    } else {
        Intent::Move(Action::Archive)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Key, Kind};

    /// The preference this reads is a `Choice` key in the schema, and the
    /// schema is what the server validates against. An enum variant with no
    /// matching token would be a dispose action the server rejects with a 400;
    /// a token with no variant would fall through `from_name` and be read as
    /// no preference at all.
    #[test]
    fn the_actions_are_exactly_the_ones_the_schema_accepts() {
        let Kind::Choice(accepted) = Key::DisposeAction.kind() else {
            panic!("dispose_action is no longer a choice key");
        };
        let named: Vec<&str> = [Action::Archive, Action::Trash]
            .into_iter()
            .map(Action::name)
            .collect();
        assert_eq!(named, accepted.to_vec());
        for token in accepted {
            assert!(
                Action::from_name(token).is_some(),
                "the schema accepts `{token}` and this policy does not"
            );
        }
    }

    /// The default the schema ships has to be one this policy can act on, or
    /// a fresh install has no dispose action at all.
    #[test]
    fn the_schemas_default_is_an_action() {
        assert!(Action::from_name(Key::DisposeAction.spec().default).is_some());
    }

    #[test]
    fn the_ordinary_case_files_the_message_where_the_preference_says() {
        assert_eq!(
            standard(Action::Archive, INBOX),
            Intent::Move(Action::Archive)
        );
        assert_eq!(standard(Action::Trash, INBOX), Intent::Move(Action::Trash));
        assert_eq!(
            standard(Action::Archive, "zeta0803"),
            Intent::Move(Action::Archive)
        );
    }

    /// Inside Trash the affordance is Delete Forever whichever way the
    /// preference points — checking the folder first is what makes that true.
    #[test]
    fn inside_trash_the_default_affordance_deletes_forever() {
        for preference in [Action::Archive, Action::Trash] {
            assert_eq!(standard(preference, TRASH), Intent::Purge);
        }
    }

    /// The defect: a same-folder move the server honours by handing the
    /// message a fresh UID, after which the client prunes a row for a message
    /// that never left.
    #[test]
    fn archiving_inside_archive_restores_instead() {
        assert_eq!(standard(Action::Archive, ARCHIVE), Intent::Restore);
        assert_eq!(archiving(ARCHIVE), Intent::Restore);
        assert_eq!(Intent::Restore.destination_folder(), Some(INBOX));
    }

    /// A Trash preference inside Archive is a real move, not a restore: the
    /// user asked for Trash and Archive is not where it is going.
    #[test]
    fn a_trash_preference_inside_archive_still_trashes() {
        assert_eq!(
            standard(Action::Trash, ARCHIVE),
            Intent::Move(Action::Trash)
        );
    }

    /// Archive from inside Trash is the rescue path out of the deleted pile.
    #[test]
    fn an_explicit_archive_inside_trash_is_a_real_archive() {
        assert_eq!(archiving(TRASH), Intent::Move(Action::Archive));
    }

    /// What the destructive button style and the confirmation are keyed to.
    /// Archiving and restoring are recoverable; the other two are not equally
    /// so, and only one of them is unrecoverable.
    #[test]
    fn only_what_cannot_be_undone_reads_as_destructive() {
        assert!(!Intent::Move(Action::Archive).is_destructive());
        assert!(!Intent::Restore.is_destructive());
        assert!(Intent::Move(Action::Trash).is_destructive());
        assert!(Intent::Purge.is_destructive());
    }

    /// Only the permanent delete is confirmed. Confirming a move to Trash as
    /// well would train the dialog away.
    #[test]
    fn only_the_permanent_delete_is_confirmed() {
        assert!(Intent::Purge.needs_confirmation());
        assert!(!Intent::Move(Action::Trash).needs_confirmation());
        assert!(!Intent::Move(Action::Archive).needs_confirmation());
        assert!(!Intent::Restore.needs_confirmation());
    }

    /// A purge moves nothing, and every other intent has somewhere to go.
    #[test]
    fn every_intent_but_the_purge_names_a_destination() {
        assert_eq!(Intent::Purge.destination_folder(), None);
        for intent in [
            Intent::Move(Action::Archive),
            Intent::Move(Action::Trash),
            Intent::Restore,
        ] {
            assert!(intent.destination_folder().is_some(), "{intent:?}");
        }
    }

    /// The animation runs fade then collapse and then the row is gone. An
    /// order that collapsed first would close the gap while the row was still
    /// opaque, which reads as the list jumping rather than as a row leaving.
    #[test]
    fn the_animation_fades_before_it_collapses_and_then_ends() {
        assert_eq!(
            DisposalPhase::Fading.next(),
            Some(DisposalPhase::Collapsing)
        );
        assert_eq!(DisposalPhase::Collapsing.next(), None);
    }

    /// The row has to outlive the animation drawn from it: a caller that
    /// dropped the message after the first leg would collapse an empty row.
    #[test]
    fn the_whole_animation_is_both_legs() {
        assert_eq!(
            disposal_duration(),
            DisposalPhase::Fading.duration() + DisposalPhase::Collapsing.duration()
        );
    }

    /// Long enough to be seen, short enough not to slow triage. A zero-length
    /// leg is the defect the animation exists to prevent — the row would
    /// vanish between frames.
    #[test]
    fn neither_leg_is_instant_or_slow_enough_to_notice_waiting() {
        for phase in [DisposalPhase::Fading, DisposalPhase::Collapsing] {
            let leg = phase.duration();
            assert!(
                leg >= std::time::Duration::from_millis(100)
                    && leg <= std::time::Duration::from_millis(300),
                "{phase:?} runs for {leg:?}"
            );
        }
    }

    /// No affordance may resolve to a move into the folder already on screen.
    /// That is the shape of the defect both special cases exist for.
    #[test]
    fn no_affordance_resolves_to_a_move_into_the_current_folder() {
        for folder in [INBOX, ARCHIVE, TRASH, "zeta0803"] {
            for preference in [Action::Archive, Action::Trash] {
                for intent in [standard(preference, folder), archiving(folder)] {
                    assert_ne!(
                        intent.destination_folder(),
                        Some(folder),
                        "{intent:?} in {folder} is a same-folder move"
                    );
                }
            }
        }
    }
}
