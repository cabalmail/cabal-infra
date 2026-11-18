import SwiftUI
import CabalmailKit

/// What the compose From picker opens: a filter field over the addresses the
/// user can send from, as a popover on iPadOS, macOS and visionOS and as a
/// sheet on iPhone, where the system adapts the popover.
///
/// A list rather than the `Menu` the picker used to open, because a menu
/// can't hold a text field, and someone who mints an address per contact has
/// far more of them than a menu can be scrolled through. The order is the
/// menu's (`FromPicker`): **Create new address…** first, then the matching
/// favorites, then every matching address. `FromAddressFilter` owns which
/// rows match.
///
/// Return in the field picks the first row drawn, so on the Mac, where the
/// field has focus as the popover opens, typing part of an address and
/// pressing Return is the whole interaction. Escape closes the popover.
struct FromAddressList: View {
    let addresses: [Address]
    let selected: String?
    let onPick: (Address) -> Void
    let onCreateAddress: () -> Void

    @State private var needle = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            filterField
                .padding(.horizontal)
                // Clear of the rounded top corners an iPhone sheet has.
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            List {
                Button(action: onCreateAddress) {
                    Label("Create new address…", systemImage: "plus.circle")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("compose.from.create")
                rows
            }
            .plainListStyleOffMac()
        }
        // A popover asks its content for an ideal size, and a `List`'s is
        // close to zero, so without one the popover opens as a sliver. A
        // sheet (the iPhone's adaptation) proposes its own size and ignores
        // these.
        .frame(minWidth: 300, idealWidth: 380, minHeight: 280, idealHeight: 440)
        .task {
            guard HostPlatform.current.focusesPickerFilterOnOpen else { return }
            // Set on the first pass, the focus is dropped on macOS: the
            // field's editor isn't in the window yet, and the window keeps
            // first responder (measured; `onAppear` and `defaultFocus` lose
            // it the same way). One turn later it holds.
            await Task.yield()
            filterFocused = true
        }
    }

    private var filter: FromAddressFilter {
        FromAddressFilter(addresses: addresses, needle: needle)
    }

    @ViewBuilder
    private var rows: some View {
        let filter = filter
        if filter.isEmpty {
            if !trimmedNeedle.isEmpty {
                Text("No address matches \"\(trimmedNeedle)\".")
                    .foregroundStyle(.secondary)
            }
        } else if !filter.favorites.isEmpty {
            Section(formHeader: "Favorites") {
                ForEach(filter.favorites) { row($0) }
            }
            Section(formHeader: "All addresses") {
                ForEach(filter.all) { row($0) }
            }
        } else {
            Section {
                ForEach(filter.all) { row($0) }
            }
        }
    }

    /// Styled as the address sidebar's filter field (`SidebarListHeaderRow`),
    /// the same filter over the same addresses.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter addresses", text: $needle)
                .textFieldStyle(.plain)
                .textEntry(.email)
                .autocorrectionDisabled()
                .focused($filterFocused)
                .onSubmit {
                    if let first = filter.firstMatch { onPick(first) }
                }
                .accessibilityIdentifier("compose.from.filter")
            if !needle.isEmpty {
                Button {
                    needle = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    /// One address. The address is drawn through `AddressDisplay.wrappable`
    /// because these rows wrap, on every platform, and an unbroken address
    /// hyphenates where it wraps (#1597); VoiceOver reads the raw one. The
    /// comment is drawn under it because the filter matches it, and a row
    /// that matched on its comment would otherwise not say why.
    ///
    /// The checkmark keeps its footprint on every row, so the selected row's
    /// address starts where the others' do.
    private func row(_ address: Address) -> some View {
        let isSelected = address.address == selected
        return Button {
            onPick(address)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AddressDisplay.wrappable(address.address))
                        .accessibilityLabel(address.address)
                    if let comment = address.comment, !comment.isEmpty {
                        Text(comment)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var trimmedNeedle: String {
        needle.trimmingCharacters(in: .whitespaces)
    }
}
