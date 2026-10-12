import SwiftUI

/// What a text field is for, as far as the software keyboard cares: which
/// keys it offers and whether it capitalizes.
enum TextEntryKind {
    /// Typed as written: an address's local part, a folder name, a username.
    case verbatim
    /// An email address: the `@` keyboard, no capitalization.
    case email
    /// A URL or a host name: the URL keyboard, no capitalization.
    case url
    /// Digits only: a one-time code.
    case digits
    /// A name: each word capitalized.
    case words
    /// Prose: each sentence capitalized.
    case sentences
}

extension View {
    /// Sets the software keyboard up for `kind`. macOS has no software
    /// keyboard and neither modifier, so there this is nothing. Each kind
    /// applies exactly the modifiers its fields applied before this existed,
    /// so a kind that says nothing about capitalization (or about the keys)
    /// leaves that to whatever the field inherits.
    @ViewBuilder
    func textEntry(_ kind: TextEntryKind) -> some View {
        #if os(macOS)
        self
        #else
        switch kind {
        case .verbatim:
            textInputAutocapitalization(.never)
        case .email:
            textInputAutocapitalization(.never).keyboardType(.emailAddress)
        case .url:
            textInputAutocapitalization(.never).keyboardType(.URL)
        case .digits:
            keyboardType(.numberPad)
        case .words:
            textInputAutocapitalization(.words)
        case .sentences:
            textInputAutocapitalization(.sentences)
        }
        #endif
    }
}
