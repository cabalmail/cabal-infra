import CabalmailKit
import SwiftUI

/// Root view: reconnect prompt, loading spinner, or the address list,
/// depending on where the credential lifecycle stands (see WatchAppModel).
struct ContentView: View {
    @Environment(WatchAppModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Cabalmail")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .waiting:
            waiting
        case .loading:
            ProgressView()
        case .ready(let addresses):
            list(addresses)
        case .failed(let message):
            failed(message)
        }
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.right.inward")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Open Cabalmail on your iPhone to connect this watch.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await model.refresh() }
            }
        }
    }

    private func list(_ addresses: [Address]) -> some View {
        List {
            if addresses.isEmpty {
                Text("No addresses yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(addresses, id: \.address) { address in
                row(address)
            }
        }
        .refreshable {
            await model.refresh()
        }
    }

    private func row(_ address: Address) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if address.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(address.address)
                    .font(.footnote)
                    .lineLimit(2)
            }
            if let comment = address.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
