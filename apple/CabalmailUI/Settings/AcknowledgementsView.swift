import SwiftUI
import CabalmailKit

/// Settings ▸ About ▸ Acknowledgements. Lists the third-party open-source
/// components bundled into the app and reproduces each one's license text in
/// full, satisfying the attribution terms that attach because the app is
/// distributed through the App Store.
///
/// The data comes from `CabalmailKit.Acknowledgements`, which owns the
/// bundled license resources; this view only presents it. It mirrors the
/// React admin app's "Third-party notices" section, which does the same for
/// the web client's bundled dependencies.
struct AcknowledgementsView: View {
    private let components = Acknowledgements.bundledComponents()

    var body: some View {
        Form {
            Section {
                Text(
                    "The Cabalmail app bundles the open-source components below into its "
                    + "rich-text composer. Each component's copyright and license notice is "
                    + "reproduced in full to satisfy the license's attribution requirements."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(components) { component in
                Section {
                    LabeledContent("License", value: component.license)
                    Link(destination: URL(string: component.url)!) {
                        Label("Project home", systemImage: "arrow.up.right.square")
                    }
                    DisclosureGroup("License text") {
                        Text(licenseText(for: component))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text(component.name)
                } footer: {
                    Text(component.summary)
                        .sectionFooter()
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Acknowledgements")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Falls back to a clear message rather than an empty pane when the
    /// vendored license resource is missing (a local build that skipped
    /// `sync-vendored.sh`). Production and CI builds always run it.
    private func licenseText(for component: ThirdPartyComponent) -> String {
        component.licenseText.isEmpty
            ? "License text is unavailable in this build. See \(component.url)."
            : component.licenseText
    }
}
