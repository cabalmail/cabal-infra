import SwiftUI

/// The Message menu's Previous and Next, one row of two buttons nearest the
/// bar: they ask the window's list to open the row above or below the open
/// message (`WindowCommand.step`), and dim at either end of the list and
/// while its next page loads (`WindowCommands.listStep(in:)`). A view of its
/// own so it reads the window's commands where it sits.
struct ReaderListStepRow: View {
    @Environment(\.windowCommands) private var commands
    @Environment(\.commandTab) private var tab

    var body: some View {
        let available = commands?.listStep(in: tab) ?? .none
        ControlGroup {
            button(.previous, title: "Previous", systemImage: "arrow.up", enabled: available.canPrevious)
            button(.next, title: "Next", systemImage: "arrow.down", enabled: available.canNext)
        }
    }

    private func button(_ step: ListStep, title: String, systemImage: String, enabled: Bool) -> some View {
        Button {
            commands?.send(.step(step))
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!enabled)
    }
}
