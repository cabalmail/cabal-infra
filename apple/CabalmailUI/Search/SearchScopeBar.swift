import SwiftUI

/// The All / Mail / Feeds control at the top of a search's results, the
/// same on every layout (flags-and-cross-media.md, decision 17).
struct SearchScopeBar: View {
    let scope: SearchScope
    let pick: (SearchScope) -> Void

    var body: some View {
        Picker("Search in", selection: Binding(get: { scope }, set: { pick($0) })) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("search.scope")
    }
}
