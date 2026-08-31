import XCTest
@testable import Cabalmail

// Regression coverage for issue #1370: focusing the compose body scrolled
// the form not at all, so the keyboard and its input-accessory bar covered
// the Rich Text / Markdown picker, the whole formatting toolbar and every
// character typed — the message was composed blind. The body is a
// WKWebView, invisible to SwiftUI's focus system, and the UIKit behaviour
// that used to scroll the ancestor Form for it is not dependable — measured
// failing on iOS 26 as well as 27. The form scrolls the editor into view
// itself now, off the editor's DOM-focus callback and off the keyboard
// appearing.
final class ComposeBodyScrollPolicyTests: XCTestCase {

    // MARK: - The rule

    /// iPhone and iPad are where the keyboard insets the form, and the
    /// generations are deliberately not split: iOS 26 was measured leaving
    /// the editor under the keyboard too, so an `#available(iOS 27)` gate
    /// would have left the reported symptom on the current OS.
    func testTheFormScrollsItselfOnIOS() {
        XCTAssertTrue(ComposeBodyScrollPolicy.appMustScrollBodyIntoView(on: .iOS))
    }

    /// macOS puts the editor below a fixed header with no keyboard inset,
    /// and visionOS floats its keyboard outside the scene. Scrolling a form
    /// that never moved would be a jump out of nowhere.
    func testTheOtherPlatformsAreLeftAlone() {
        XCTAssertFalse(ComposeBodyScrollPolicy.appMustScrollBodyIntoView(on: .macOS))
        XCTAssertFalse(ComposeBodyScrollPolicy.appMustScrollBodyIntoView(on: .visionOS))
        XCTAssertFalse(ComposeBodyScrollPolicy.appMustScrollBodyIntoView(on: .watchOS))
    }

    // MARK: - The form wires it up

    /// The rule is inert unless the form actually watches the editor's DOM
    /// focus and has a `ScrollViewProxy` to act on. Neither is reachable
    /// from a unit test — `ComposeView.composeForm` is iOS-only and builds
    /// no inspectable value — so this reads the source.
    func testTheFormScrollsWhenTheEditorTakesFocus() throws {
        let source = try Self.composeViewSource()
        XCTAssertTrue(
            Self.formScrollsBodyOnEditorFocus(in: source),
            "the compose Form must sit in a ScrollViewReader and watch model.editorFocused (#1370)"
        )
    }

    /// The other order the form has to survive: the editor takes focus with
    /// no keyboard up, so the focus-driven scroll runs against a form with
    /// no keyboard inset and clamps short. Without a second pass on the
    /// keyboard's arrival the editor lands back under it — measured on the
    /// iOS 26 sim, editor top y=591 against a keyboard top of ~524.
    func testTheFormScrollsAgainWhenTheKeyboardArrives() throws {
        XCTAssertTrue(
            Self.formRescrollsWhenTheKeyboardArrives(in: try Self.composeViewSource()),
            "a keyboard that appears after focus must re-run the scroll (#1370)"
        )
    }

    /// `scrollTo` needs a row registered under exactly this identity, and
    /// `.top` is the anchor: the editor is the tallest thing in the form,
    /// so anything else leaves the caret under the keyboard again.
    func testTheBodyRowIsTheScrollTargetAndLandsAtTheTop() throws {
        let source = try Self.composeViewSource()
        XCTAssertTrue(
            Self.bodyRowCarriesScrollTarget(in: source),
            "the ComposerBody row must carry ComposeBodyScrollPolicy.bodyScrollTarget"
        )
        XCTAssertTrue(
            Self.scrollsToTargetAnchoredAtTop(in: source),
            "the scroll must name the same target and anchor it at .top"
        )
    }

    // MARK: - Detector self-tests

    /// Proves the form scan calls the shipped shape fixed and the shape that
    /// was on `origin/stage` broken, so the assertions above cannot pass
    /// vacuously after a rewrite. The "broken" snippet is copied
    /// byte-for-byte off the pre-fix file.
    func testFormDetectorSeesThePreFixAndPostFixShapes() {
        let brokenForm = """
        private var composeForm: some View {
            Form {
                ForEach(ComposeFormSection.allCases, id: \\.self) { section in
                    formSection(section)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                composeErrorBanner
            }
        }
        """
        XCTAssertFalse(Self.formScrollsBodyOnEditorFocus(in: brokenForm))
        XCTAssertFalse(Self.scrollsToTargetAnchoredAtTop(in: brokenForm))

        // A reader with no focus observer is the trap worth catching: it
        // compiles, it reads as "handled", and it scrolls nothing.
        let readerWithoutObserver = """
        private var composeForm: some View {
            ScrollViewReader { proxy in
                Form {
                    ForEach(ComposeFormSection.allCases, id: \\.self) { section in
                        formSection(section)
                    }
                }
            }
        }
        """
        XCTAssertFalse(Self.formScrollsBodyOnEditorFocus(in: readerWithoutObserver))

        let fixedForm = """
        private var composeForm: some View {
            ScrollViewReader { proxy in
                Form {
                    ForEach(ComposeFormSection.allCases, id: \\.self) { section in
                        formSection(section)
                    }
                }
                .onChange(of: model.editorFocused) { _, focused in
                    scrollBodyClearOfKeyboard(focused: focused, proxy: proxy)
                }
            }
        }
        proxy.scrollTo(ComposeBodyScrollPolicy.bodyScrollTarget, anchor: .top)
        """
        XCTAssertTrue(Self.formScrollsBodyOnEditorFocus(in: fixedForm))
        XCTAssertTrue(Self.scrollsToTargetAnchoredAtTop(in: fixedForm))
    }

    /// Focus alone was the first shape that looked right, and it still left
    /// the editor under a keyboard that arrived after focus — so the
    /// keyboard scan has to reject it.
    func testKeyboardDetectorSeesFocusOnlyAsIncomplete() {
        let focusOnly = """
        .onChange(of: model.editorFocused) { _, focused in
            scrollBodyClearOfKeyboard(focused: focused, proxy: proxy)
        }
        """
        let withKeyboard = focusOnly + """
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardDidShowNotification
        )) { _ in
            scrollBodyClearOfKeyboard(focused: model.editorFocused, proxy: proxy)
        }
        """
        XCTAssertFalse(Self.formRescrollsWhenTheKeyboardArrives(in: focusOnly))
        XCTAssertTrue(Self.formRescrollsWhenTheKeyboardArrives(in: withKeyboard))
    }

    /// Same for the row scan: the identity `scrollTo` resolves has to be on
    /// the body row, and its absence is what the reported build shipped.
    func testRowDetectorSeesThePreFixAndPostFixShapes() {
        let brokenRow = """
        case .message:
            Section("Message") {
                ComposerBody(model: model)
            }
        """
        let fixedRow = """
        case .message:
            Section("Message") {
                ComposerBody(model: model)
                    .id(ComposeBodyScrollPolicy.bodyScrollTarget)
            }
        """
        XCTAssertFalse(Self.bodyRowCarriesScrollTarget(in: brokenRow))
        XCTAssertTrue(Self.bodyRowCarriesScrollTarget(in: fixedRow))
    }

    // MARK: - Extraction

    /// True when the compose `Form` is inside a `ScrollViewReader` *and*
    /// something observes the editor's focus flag. Either alone is dead
    /// code.
    private static func formScrollsBodyOnEditorFocus(in source: String) -> Bool {
        source.contains("ScrollViewReader { proxy in")
            && source.contains(".onChange(of: model.editorFocused)")
    }

    /// True when the body row is followed, before its enclosing view ends,
    /// by the identity `scrollTo` resolves.
    private static func bodyRowCarriesScrollTarget(in source: String) -> Bool {
        guard let row = source.range(of: "ComposerBody(model: model)") else { return false }
        let tail = source[row.upperBound...].prefix(while: { $0 != "}" })
        return tail.contains(".id(ComposeBodyScrollPolicy.bodyScrollTarget)")
    }

    /// True when the keyboard's own arrival re-runs the scroll against the
    /// editor's focus state.
    private static func formRescrollsWhenTheKeyboardArrives(in source: String) -> Bool {
        source.contains("UIResponder.keyboardDidShowNotification")
            && source.contains("scrollBodyClearOfKeyboard(focused: model.editorFocused, proxy: proxy)")
    }

    private static func scrollsToTargetAnchoredAtTop(in source: String) -> Bool {
        source.contains("scrollTo(ComposeBodyScrollPolicy.bodyScrollTarget, anchor: .top)")
    }

    private static func composeViewSource() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(
            contentsOf: apple.appendingPathComponent("Cabalmail/Views/ComposeView.swift"),
            encoding: .utf8
        )
    }
}
