import SwiftUI

/// A form section's header at the interface text size (`AppTextSize`).
///
/// At `.medium` the header is the form's own; at any other size it is the
/// headline style at that size, which is what a grouped form draws its
/// headers in. Without it the scene root's default font (`appTextSize()`)
/// would set the header in plain body text, the same as the rows under it.
/// `FormSectionTextSourceScanTests` holds every header to this, and the
/// `string_titled_section` SwiftLint rule turns `Section("Title")` into
/// `Section(formHeader: "Title")`, which builds one.
struct FormSectionHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.appFontWhenScaled(.headline)
    }
}

/// A form section's footer at the interface text size: the form's own at
/// `.medium`, the subheadline style at that size otherwise, which is the
/// size a grouped form draws its footers in on the Mac.
struct FormSectionFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.appFontWhenScaled(.subheadline)
    }
}

extension Section where Parent == FormSectionHeader<Text>, Footer == EmptyView, Content: View {
    /// A section titled with a string, its header drawn by
    /// `FormSectionHeader`: the form-scaled stand-in for `Section("Title")`.
    init(formHeader title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            FormSectionHeader { Text(title) }
        }
    }
}
