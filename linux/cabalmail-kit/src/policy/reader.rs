//! Which actions the reader's header bar draws, which ride its menu, and how
//! tall the scrollable header block may be.
//!
//! The Apple analogs are `ReaderToolbarLayout` and `ReaderHeaderHeightPolicy`.
//! What ports is the budget and the demotion order; what does not is the
//! platform arithmetic behind them — half of `ReaderToolbarLayout` is about
//! which iOS SDK folds a `.bottomBar` at what width, and libadwaita has no
//! equivalent behaviour. An `AdwHeaderBar` draws exactly what it is packed
//! with, so here the budget is ours to spend rather than a ceiling the toolkit
//! imposes.

/// One control in the reader's action set.
///
/// Named rather than numbered so a widget can carry the name as its
/// accessibility identifier, which is how the Apple client's UI tests address
/// the same buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Reply,
    EditDraft,
    ToggleRead,
    ToggleFlag,
    RemoteContent,
    ReaderMode,
    Dispose,
    Move,
    PlainText,
    ViewSource,
    ViewHeaders,
    Print,
}

impl Action {
    /// The action's stable name: a widget's accessibility identifier, and the
    /// `win.<name>` action it activates.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Reply => "reply",
            Self::EditDraft => "edit-draft",
            Self::ToggleRead => "toggle-read",
            Self::ToggleFlag => "toggle-flag",
            Self::RemoteContent => "remote-content",
            Self::ReaderMode => "reader-mode",
            Self::Dispose => "dispose",
            Self::Move => "move",
            Self::PlainText => "plain-text",
            Self::ViewSource => "view-source",
            Self::ViewHeaders => "view-headers",
            Self::Print => "print",
        }
    }
}

/// What the leading action is for the message on screen. A draft opens for
/// editing; everything else is replied to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Leading {
    Reply,
    EditDraft,
}

impl Leading {
    fn action(self) -> Action {
        match self {
            Self::Reply => Action::Reply,
            Self::EditDraft => Action::EditDraft,
        }
    }
}

/// Buttons the header bar draws in a narrow pane. Four plus the menu button is
/// what fits beside a title at the collapse width without the title eliding.
pub const NARROW_BUTTON_BUDGET: usize = 4;

/// Buttons a pane at least [`FULL_SET_MIN_WIDTH_SP`] wide draws — the narrow
/// set plus the two display toggles.
pub const WIDE_BUTTON_BUDGET: usize = NARROW_BUTTON_BUDGET + 2;

/// Narrowest pane at which the two display toggles are drawn as buttons rather
/// than menu rows.
///
/// They are the cheapest slots to reclaim: both are inert on plain-text mail,
/// disabling themselves when there is no HTML body. Above this width there is
/// room for them beside the rest.
pub const FULL_SET_MIN_WIDTH_SP: i32 = 560;

/// The most of the reading pane the header block may claim. Beyond this the
/// body starts to disappear, so a pathological header — a subject that wraps
/// five times, a sprawling Cc list — scrolls inside the block instead of
/// pushing the message off screen.
pub const MAX_HEADER_PANE_FRACTION: f64 = 0.45;

/// How many actions the bar draws in a pane `width_sp` wide.
#[must_use]
pub fn button_budget(width_sp: i32) -> usize {
    if width_sp >= FULL_SET_MIN_WIDTH_SP {
        WIDE_BUTTON_BUDGET
    } else {
        NARROW_BUTTON_BUDGET
    }
}

/// The actions drawn as buttons, in order, for a pane `width_sp` wide.
///
/// *Which* actions is the budget applied to [`all`]'s demotion order, so the
/// order declared there is the order things leave the bar rather than a
/// comment about it. *Where* they are drawn is a separate arrangement:
/// promotion grows the middle of the bar, so the leading action keeps the
/// leading edge and dispose the trailing one, and widening the pane never
/// moves the endpoint hit targets.
#[must_use]
pub fn header_bar(leading: Leading, width_sp: i32) -> Vec<Action> {
    let drawn: Vec<Action> = all(leading)
        .into_iter()
        .take(button_budget(width_sp))
        .collect();
    arrange(&drawn, leading)
}

/// Puts a set of drawn actions in the order the bar packs them.
///
/// The leading action first and dispose last, with everything else between in
/// demotion order. Both endpoints are actions the bar always draws, at every
/// width, which is what makes them safe to pin there.
fn arrange(drawn: &[Action], leading: Leading) -> Vec<Action> {
    let mut arranged = Vec::with_capacity(drawn.len());
    arranged.extend(
        drawn
            .iter()
            .copied()
            .filter(|action| *action == leading.action()),
    );
    arranged.extend(
        drawn
            .iter()
            .copied()
            .filter(|action| *action != leading.action() && *action != Action::Dispose),
    );
    arranged.extend(
        drawn
            .iter()
            .copied()
            .filter(|action| *action == Action::Dispose),
    );
    arranged
}

/// The actions that ride the header bar's menu, in demotion order — everything
/// the bar did not draw.
#[must_use]
pub fn menu(leading: Leading, width_sp: i32) -> Vec<Action> {
    all(leading)
        .into_iter()
        .skip(button_budget(width_sp))
        .collect()
}

/// Every action the reader offers for this message, in demotion order: the
/// first is the last to leave the bar, the last is the first to go to the
/// menu. Reply and Edit Draft are alternatives, never both.
///
/// The bar and the menu are both taken from this list, so it is the one place
/// the order is decided. It is not Apple's order — `ReaderToolbarLayout`
/// arranges for AppKit to do its demoting, and libadwaita demotes nothing on
/// its own.
#[must_use]
pub fn all(leading: Leading) -> Vec<Action> {
    vec![
        leading.action(),
        Action::ToggleRead,
        Action::ToggleFlag,
        Action::Dispose,
        Action::RemoteContent,
        Action::ReaderMode,
        Action::Move,
        Action::PlainText,
        Action::ViewSource,
        Action::ViewHeaders,
        Action::Print,
    ]
}

/// How tall the reader's scrollable header block may be, given what it needs
/// and how much room the pane has.
///
/// With no pane to divide up yet, the header asks for exactly what it needs.
/// Before the first measurement it takes the cap rather than zero — a
/// zero-height header collapses the block on the first layout pass.
#[must_use]
pub fn header_height(content_height: f64, pane_height: f64) -> f64 {
    if pane_height <= 0.0 {
        return content_height.max(0.0);
    }
    let cap = pane_height * MAX_HEADER_PANE_FRACTION;
    if content_height <= 0.0 {
        return cap;
    }
    content_height.min(cap)
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIDTHS: &[i32] = &[
        0,
        320,
        FULL_SET_MIN_WIDTH_SP - 1,
        FULL_SET_MIN_WIDTH_SP,
        1600,
        i32::MAX,
    ];

    /// The whole point of the split: every action is reachable at every width,
    /// as a button or as a menu row, and never as both. Order is the bar's
    /// business and differs from the demotion order `all` declares, so this
    /// counts rather than compares.
    #[test]
    fn every_action_is_reachable_exactly_once_at_every_width() {
        for leading in [Leading::Reply, Leading::EditDraft] {
            for width in WIDTHS.iter().copied() {
                let mut reachable = header_bar(leading, width);
                reachable.extend(menu(leading, width));
                assert_eq!(
                    reachable.len(),
                    all(leading).len(),
                    "at {width}sp the reader offers {reachable:?}"
                );
                for action in all(leading) {
                    assert_eq!(
                        reachable.iter().filter(|drawn| **drawn == action).count(),
                        1,
                        "{action:?} is not offered exactly once at {width}sp: {reachable:?}"
                    );
                }
            }
        }
    }

    /// A bar that outgrew its budget is what sends the toolkit looking for
    /// somewhere to put the overflow, which on every platform it has been
    /// tried on is somewhere worse than our own menu.
    #[test]
    fn the_bar_never_exceeds_the_budget_for_its_width() {
        for leading in [Leading::Reply, Leading::EditDraft] {
            for width in WIDTHS.iter().copied() {
                let budget = if width >= FULL_SET_MIN_WIDTH_SP {
                    WIDE_BUTTON_BUDGET
                } else {
                    NARROW_BUTTON_BUDGET
                };
                let drawn = header_bar(leading, width);
                assert!(
                    drawn.len() <= budget,
                    "{} buttons at {width}sp, budget {budget}",
                    drawn.len()
                );
            }
        }
    }

    /// The invariant that makes `all`'s order mean something: the bar is the
    /// front of that list and the menu is the back. Without this the declared
    /// demotion order could be reshuffled and nothing would move.
    #[test]
    fn the_bar_is_the_front_of_the_demotion_order_and_the_menu_is_the_back() {
        for leading in [Leading::Reply, Leading::EditDraft] {
            for width in WIDTHS.iter().copied() {
                let every = all(leading);
                let budget = button_budget(width);
                let mut drawn = header_bar(leading, width);
                drawn.sort_by_key(|action| {
                    every
                        .iter()
                        .position(|other| other == action)
                        .expect("declared")
                });
                assert_eq!(drawn, every[..budget].to_vec(), "at {width}sp");
                assert_eq!(
                    menu(leading, width),
                    every[budget..].to_vec(),
                    "at {width}sp"
                );
            }
        }
    }

    /// Reply and Edit Draft are one slot, not two: a draft is opened for
    /// editing and a received message is replied to, and offering both would
    /// make one of them inert on every message.
    #[test]
    fn the_leading_action_is_the_one_the_message_calls_for() {
        assert_eq!(header_bar(Leading::Reply, 1600)[0], Action::Reply);
        assert_eq!(header_bar(Leading::EditDraft, 1600)[0], Action::EditDraft);
        for leading in [Leading::Reply, Leading::EditDraft] {
            let every = all(leading);
            assert_eq!(
                every.contains(&Action::Reply),
                leading == Leading::Reply,
                "both leading actions are offered at once"
            );
        }
    }

    /// Widening the pane promotes the display toggles into the middle. The
    /// endpoints must not move with them — a button that slides out from under
    /// the pointer as the divider is dragged is the failure this ordering
    /// avoids.
    #[test]
    fn promotion_grows_the_middle_and_leaves_the_endpoints_alone() {
        let narrow = header_bar(Leading::Reply, FULL_SET_MIN_WIDTH_SP - 1);
        let wide = header_bar(Leading::Reply, FULL_SET_MIN_WIDTH_SP);
        assert_eq!(narrow.first(), wide.first());
        assert_eq!(narrow.last(), wide.last());
        assert_eq!(narrow.len() + 2, wide.len());
        assert!(wide.contains(&Action::RemoteContent) && wide.contains(&Action::ReaderMode));
        assert!(!narrow.contains(&Action::RemoteContent) && !narrow.contains(&Action::ReaderMode));
    }

    /// Both halves of an action's identity are written once. A duplicate name
    /// would have two buttons activating one `win.` action.
    #[test]
    fn every_action_name_is_distinct_and_shell_plain() {
        let names: Vec<&str> = all(Leading::Reply)
            .into_iter()
            .chain(std::iter::once(Action::EditDraft))
            .map(Action::name)
            .collect();
        for name in &names {
            assert!(
                !name.is_empty()
                    && name
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte == b'-'),
                "`{name}` is not a lowercase, hyphenated single word"
            );
            assert_eq!(
                names.iter().filter(|other| *other == name).count(),
                1,
                "`{name}` names two actions"
            );
        }
    }

    #[test]
    fn an_unmeasured_header_takes_the_cap_rather_than_nothing() {
        assert!((header_height(0.0, 800.0) - 360.0).abs() < f64::EPSILON);
    }

    #[test]
    fn a_header_that_fits_gets_what_it_asked_for() {
        assert!((header_height(120.0, 800.0) - 120.0).abs() < f64::EPSILON);
    }

    /// The defect the cap exists for: a header long enough to leave no message
    /// on screen.
    #[test]
    fn a_sprawling_header_is_capped_at_its_share_of_the_pane() {
        assert!((header_height(5000.0, 800.0) - 360.0).abs() < f64::EPSILON);
    }

    /// The first layout pass, before the pane has a height. Asking for the
    /// content's own height is the only answer that is not a guess.
    #[test]
    fn an_unmeasured_pane_imposes_no_cap() {
        assert!((header_height(120.0, 0.0) - 120.0).abs() < f64::EPSILON);
        assert!((header_height(-5.0, 0.0)).abs() < f64::EPSILON);
    }
}
