import SwiftUI
import CabalmailKit

/// Settings → Debug Log. Tails `DebugLogStore.shared` and renders the most
/// recent entries as a scrollable list. Phase 7 ships this as a debugging
/// aid: a user who hits a weird failure can open the log, hit Share, and
/// attach the transcript to a GitHub issue instead of bisecting blind.
///
/// Kept in SwiftUI (rather than OSLog's Console.app viewer) because on iOS
/// there's no developer-level log viewer inside the device, and asking
/// users to attach a Mac for every "doesn't work" report isn't reasonable.
struct DebugLogView: View {
    @State private var entries: [DebugLogStore.Entry] = []
    @State private var streamTask: Task<Void, Never>?
    @State private var selectedLevels: Set<DebugLogStore.Level> = Set(DebugLogStore.Level.allCases)

    var body: some View {
        List {
            filterSection
            ForEach(filtered) { entry in
                LogRow(entry: entry)
            }
        }
        .navigationTitle("Debug Log")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: shareText) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        Task { await DebugLogStore.shared.clear() }
                        entries = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await tailLog() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            // Each level toggles independently — errors-only is the useful
            // default for bug reports, while full-verbose (all four levels
            // on) is what engineers want when diagnosing live.
            HStack {
                ForEach(DebugLogStore.Level.allCases, id: \.self) { level in
                    levelChip(level)
                }
            }
        }
    }

    @ViewBuilder
    private func levelChip(_ level: DebugLogStore.Level) -> some View {
        let enabled = selectedLevels.contains(level)
        Button {
            if enabled { selectedLevels.remove(level) } else { selectedLevels.insert(level) }
        } label: {
            Text(level.rawValue.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    enabled ? tint(for: level).opacity(0.2) : Color.gray.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(enabled ? tint(for: level) : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [DebugLogStore.Entry] {
        entries
            .filter { selectedLevels.contains($0.level) }
            .reversed()
    }

    /// Renders the full unfiltered log as one big string for ShareLink. Reading
    /// the snapshot synchronously via `entries` skips another actor hop —
    /// the stream task keeps `entries` current.
    private var shareText: String {
        entries.map { line in
            let stamp = Self.timestampFormatter.string(from: line.timestamp)
            return "[\(stamp)] \(line.level.rawValue.uppercased()) \(line.category): \(line.message)"
        }.joined(separator: "\n")
    }

    private func tint(for level: DebugLogStore.Level) -> Color {
        switch level {
        case .debug: return .gray
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        }
    }

    /// Initial snapshot + streaming tail. Buffer cap of 1000 keeps memory
    /// bounded even when a runaway loop logs thousands of lines per minute.
    private func tailLog() async {
        let store = DebugLogStore.shared
        let snapshot = await store.snapshot()
        entries = snapshot
        streamTask?.cancel()
        streamTask = Task { @MainActor in
            let stream = await store.newEntries()
            for await entry in stream {
                if Task.isCancelled { break }
                entries.append(entry)
                if entries.count > 1000 {
                    entries.removeFirst(entries.count - 1000)
                }
            }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct LogRow: View {
    let entry: DebugLogStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(levelLabel)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(tint)
                Text(entry.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timestamp)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private var levelLabel: String { entry.level.rawValue.uppercased() }

    private var tint: Color {
        switch entry.level {
        case .debug: return .gray
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        }
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
}
