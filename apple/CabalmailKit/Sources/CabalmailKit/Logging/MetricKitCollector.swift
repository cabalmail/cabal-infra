import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Opt-in crash & hang collector — funnels MetricKit diagnostic payloads
/// into `DebugLogStore` so the Settings → Debug Log view shows them after
/// the next launch.
///
/// The plan calls for MetricKit over a third-party SDK. MetricKit delivers
/// both metrics (daily) and *diagnostics* (per-payload) via
/// `MXMetricManagerSubscriber`. We only care about diagnostics here — the
/// metrics stream is useful for production telemetry pipelines but would
/// need a server to ship them to. Diagnostics give us crash, hang, CPU,
/// and disk-write reports without any ingress infrastructure.
///
/// Activated by `CabalmailClient.enableCrashReporting()` — off by default
/// because the plan marks it opt-in.
public final class MetricKitCollector: NSObject, @unchecked Sendable {
    private let store: DebugLogStore
    private var isActive = false

    public init(store: DebugLogStore = .shared) {
        self.store = store
    }

    public func start() {
        #if canImport(MetricKit) && !os(visionOS)
        guard !isActive else { return }
        MXMetricManager.shared.add(self)
        isActive = true
        #endif
    }

    public func stop() {
        #if canImport(MetricKit) && !os(visionOS)
        guard isActive else { return }
        MXMetricManager.shared.remove(self)
        isActive = false
        #endif
    }

    deinit {
        stop()
    }
}

#if canImport(MetricKit) && !os(visionOS)
extension MetricKitCollector: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Metrics (daily rollups) aren't useful without an ingestion
        // endpoint; log that a payload arrived so debug users can verify
        // MetricKit is firing, and stop there.
        let store = store
        for payload in payloads {
            let snippet = "metrics payload \(payload.timeStampBegin)→\(payload.timeStampEnd)"
            Task { await store.log(.info, "MetricKit", snippet) }
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let store = store
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let message = "crash: \(crash.terminationReason ?? "(unknown)") " +
                    "sig=\(crash.signal?.stringValue ?? "?") " +
                    "exc=\(crash.exceptionType?.stringValue ?? "?")"
                Task { await store.log(.error, "MetricKit", message) }
            }
            for hang in payload.hangDiagnostics ?? [] {
                let duration = hang.hangDuration.converted(to: .seconds).value
                let message = "hang: \(String(format: "%.2fs", duration))"
                Task { await store.log(.warn, "MetricKit", message) }
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                let message = "cpu exception: totalCPUTime=\(cpu.totalCPUTime) totalSampledTime=\(cpu.totalSampledTime)"
                Task { await store.log(.warn, "MetricKit", message) }
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                let message = "disk write exception: totalWritesCaused=\(disk.totalWritesCaused)"
                Task { await store.log(.warn, "MetricKit", message) }
            }
        }
    }
}
#endif
