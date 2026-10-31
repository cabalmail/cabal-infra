import CoreGraphics
import Foundation

/// The pure rules of compose in laptop pose (#1649): a horizontal fold
/// across the compose sheet, the iPhone Duo held like a laptop. The message
/// sits above the fold and From, To, Cc, Bcc, Subject and the attachments
/// below it; while the keyboard is down, Cancel, Attach, Edit Message, Open
/// in New Window and Send sit in a bar at the bottom, and the formatting
/// controls fold away. While the software keyboard is up it fills the space
/// below the fold, so Cancel, Attach and Send go back to the top bar, the
/// decided exception to the rule of no taps above a laptop fold.
///
/// Every output with no laptop fold is today's: iPhone, iPad, the Mac,
/// visionOS and the Duo flat, closed or in book pose see no change. And
/// every change these rules drive is a value on a modifier that is always
/// present, never an `if` or an `.id` around the body or a field: those
/// would rebuild the editor's web view and drop focus (measured, 2026-10-31).
enum ComposeLaptopPolicy {
    /// Where compose's bar buttons sit.
    enum BarHost: Equatable {
        /// Today's navigation bar: no laptop fold.
        case navigationBar
        /// Laptop pose with the software keyboard up: Cancel, Attach and
        /// Send in the top bar, nothing else.
        case laptopTop
        /// Laptop pose at rest: every button in a bar at the bottom.
        case laptopBottom

        /// The bottom bar's group is drawn.
        var drawsBottomGroup: Bool { self == .laptopBottom }
        /// Open in New Window sits in the top bar, where it is today.
        var offersWindowInTopBar: Bool { self == .navigationBar }
    }

    /// Where the body sat at the form's top at rest, and the space from its
    /// bottom to the From header, as laid out: what the body's height is
    /// worked out from.
    struct RestMetrics: Equatable {
        var bodyTop: CGFloat
        var gap: CGFloat
    }

    /// The body's height in laptop pose, and the blank padding under it that
    /// carries the From header below the fold when the rows' own spacing
    /// falls short.
    struct BodyFrame: Equatable {
        var height: CGFloat?
        var bridge: CGFloat

        /// Today's: the body's own height and no padding.
        static let natural = BodyFrame(height: nil, bridge: 0)
    }

    /// The body's own minimum height (`ComposerBody`), which a laptop
    /// height never goes under.
    static let bodyFloor: CGFloat = 240
    /// The grouped row's blank under the body, measured on the Duo
    /// simulator (the row's bottom 15 pt below the editor's).
    static let bodyCellOutset: CGFloat = 15
    /// How close to the form's top counts as at its top.
    static let restTolerance: CGFloat = 0.5
    /// How long after the user's own scroll the form stays where they put it.
    static let userScrollQuiet: TimeInterval = 0.6

    /// The software keyboard is up: it covers more than half the space below
    /// the fold. A hardware keyboard's bar, a hidden keyboard's end frame
    /// and no keyboard at all are down.
    static func keyboardIsUp(_ keyboard: CGRect?, crease: CGRect) -> Bool {
        guard let keyboard, keyboard.height > 0 else { return false }
        return keyboard.minY < (crease.maxY + keyboard.maxY) / 2
    }

    /// Where the bar buttons go: a nil crease is no laptop fold.
    static func barHost(crease: CGRect?, keyboard: CGRect?) -> BarHost {
        guard let crease else { return .navigationBar }
        return keyboardIsUp(keyboard, crease: crease) ? .laptopTop : .laptopBottom
    }

    /// The body's height: down to the fold, with its row's blank above it,
    /// and no taller than puts the From header at the fold's lower edge; any
    /// space left between them is bridged with padding, so the header never
    /// sits in the band. Never under the body's own floor.
    static func bodyFrame(crease: CGRect?, rest: RestMetrics?, cellOutset: CGFloat = bodyCellOutset) -> BodyFrame {
        guard let crease, let rest else { return .natural }
        let toFold = crease.minY - cellOutset - rest.bodyTop
        let toFields = crease.maxY - rest.gap - rest.bodyTop
        let height = max(bodyFloor, min(toFold, toFields))
        return BodyFrame(height: height, bridge: max(0, toFields - height))
    }

    /// The rest metrics from the body's frame (read outside its height and
    /// padding) and the From header's top, to the half point.
    static func restMetrics(bodyFrame: CGRect, fieldsTop: CGFloat) -> RestMetrics {
        RestMetrics(bodyTop: halfPoint(bodyFrame.minY), gap: halfPoint(fieldsTop - bodyFrame.maxY))
    }

    /// Whether the frames now are the rest the body's height is worked out
    /// from: laptop pose at rest, idle, at the form's top.
    static func samplesRest(host: BarHost, isScrolling: Bool, scrolledFromRest: CGFloat) -> Bool {
        host == .laptopBottom && !isScrolling && abs(scrolledFromRest) <= restTolerance
    }

    /// Whether the form goes back to its top as the bars move below the
    /// fold: not while it scrolls, nor right after the user's own scroll,
    /// which leaves it where they put it.
    static func returnsToRest(host: BarHost, isScrolling: Bool, sinceUserScroll: TimeInterval?) -> Bool {
        guard host == .laptopBottom, !isScrolling else { return false }
        guard let sinceUserScroll else { return true }
        return sinceUserScroll > userScrollQuiet
    }

    /// The Rich Text and Markdown picker and the formatting controls fold
    /// away at rest in laptop pose, and come back while either editor has
    /// focus (a hardware keyboard) or the software keyboard is up.
    static func formattingHidden(host: BarHost, editorFocused: Bool, markdownFocused: Bool) -> Bool {
        host == .laptopBottom && !editorFocused && !markdownFocused
    }

    /// The window y a toast sits below: the fold's lower edge at rest in
    /// laptop pose, else nil (today's top).
    static func toastFloor(host: BarHost, crease: CGRect?) -> CGFloat? {
        guard host == .laptopBottom, let crease else { return nil }
        return crease.maxY
    }

    /// Edit Message is live once the draft has started and is held, while
    /// nothing is sending, and with an editor to put the caret back in.
    static func mayEditMessage(
        hasStarted: Bool, holdsDraft: Bool, isSending: Bool, isMarkdown: Bool, editorDown: Bool
    ) -> Bool {
        hasStarted && holdsDraft && !isSending && (isMarkdown || !editorDown)
    }

    private static func halfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

/// Where a toast sits under a window y: its top padding inside the overlay,
/// whose safe top (in window coordinates) is `safeTop`. Today's 6 pt with
/// nothing to sit under.
enum ToastPlacement {
    static func topPadding(below: CGFloat?, safeTop: CGFloat) -> CGFloat {
        below.map { max(6, $0 - safeTop + 6) } ?? 6
    }
}
