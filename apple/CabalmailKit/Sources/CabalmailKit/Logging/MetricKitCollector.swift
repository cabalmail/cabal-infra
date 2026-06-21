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
    /// Process-lifetime singleton. MetricKit subscription is global to the
    /// process (`MXMetricManager.shared`), so the subscriber object must
    /// outlive any per-session object that toggles it.
    ///
    /// This used to be owned by `CabalmailClient`, which is created on sign-in
    /// and released on sign-out. On sign-out the client (and this collector)
    /// deallocated, and `deinit` called `MXMetricManager.shared.remove(self)`.
    /// That removal is dispatched asynchronously onto
    /// `com.apple.metrickit.manager.queue`; by the time the hash-table
    /// mutation ran, the collector was already freed, so `removeSubscriber:`
    /// sent `-hash` to a dangling pointer -- a use-after-free that crashed the
    /// process with `EXC_BAD_ACCESS` in `-[MXMetricManager removeSubscriber:]`.
    /// Holding the collector for the whole process lifetime removes the
    /// dangling-pointer window entirely.
    public static let shared = MetricKitCollector()

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

    // Deliberately no `deinit { stop() }`. `MXMetricManager.remove(_:)` defers
    // the actual unsubscribe to a background queue, so removing from `deinit`
    // touches freed memory once the object is gone. The singleton never
    // deallocates, and `stop()` (on an explicit opt-out) always runs while the
    // collector is still alive.
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
