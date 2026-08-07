import Foundation

// Bulk-op chunking and partial-failure aggregation for the API-backed
// client (Phase 4 of `docs/0.11.x/multi-select-bulk-operations.md`). In its
// own file so `ApiBackedImapClient.swift` stays under SwiftLint's
// file-length cap; everything here is a static helper, so the actor's
// private stored state is never needed.

/// Accumulated outcome of the chunked calls behind one logical bulk op.
/// `firstError` keeps the original thrown error so a total failure can
/// surface the real cause instead of a synthetic partial-failure.
struct BulkChunkOutcome: Sendable {
    var succeeded: Set<UInt32> = []
    var failed: Set<UInt32> = []
    var firstError: (any Error)?
}

extension ApiBackedImapClient {
    /// Ceiling on UIDs per Lambda request. A timeout safety net: the Lambda
    /// already batches its IMAP commands internally (500 UIDs per command)
    /// but one request carrying tens of thousands of UIDs would still brush
    /// the 29s API Gateway limit — and the Lambdas 413 anything over their
    /// `MAX_IDS_PER_REQUEST` (5000) outright. Chunks run sequentially, not
    /// concurrently, to avoid stampeding the IMAP tier and to keep
    /// per-chunk error attribution simple.
    static let bulkChunkSize = 1000

    /// Runs `perform` over `bulkChunkSize`-sized slices of `uids`,
    /// accumulating each chunk's succeeded/failed split. A chunk that
    /// throws (network failure, Lambda `status: "unable"` 500) records all
    /// of its UIDs as failed and the walk continues — mirroring the
    /// Lambda's own `apply_in_batches` semantics — so the caller always
    /// gets a complete per-UID picture.
    static func runChunked(
        uids: [UInt32],
        perform: ([UInt32]) async throws -> BulkOpResult
    ) async -> BulkChunkOutcome {
        var outcome = BulkChunkOutcome()
        for start in stride(from: 0, to: uids.count, by: bulkChunkSize) {
            let chunk = Array(uids[start..<min(start + bulkChunkSize, uids.count)])
            do {
                let result = try await perform(chunk)
                outcome.succeeded.formUnion(result.succeeded)
                outcome.failed.formUnion(result.failed)
            } catch {
                outcome.failed.formUnion(chunk)
                if outcome.firstError == nil { outcome.firstError = error }
            }
        }
        return outcome
    }

    /// Merges the outcomes of one bulk op (several per-flag fan-out legs,
    /// or a single move) and throws when any UID failed. A UID counts as
    /// succeeded only if every leg applied it. Total failure rethrows the
    /// original error; a genuine split throws `bulkPartialFailure` so the
    /// view model can keep the succeeded UIDs applied and restore the rest.
    static func throwIfIncomplete(_ outcomes: [BulkChunkOutcome]) throws {
        let failed = outcomes.reduce(into: Set<UInt32>()) { $0.formUnion($1.failed) }
        guard !failed.isEmpty else { return }
        let succeeded = outcomes
            .reduce(into: Set<UInt32>()) { $0.formUnion($1.succeeded) }
            .subtracting(failed)
        if succeeded.isEmpty, let error = outcomes.compactMap(\.firstError).first {
            throw error
        }
        throw CabalmailError.bulkPartialFailure(succeeded: succeeded, failed: failed)
    }
}
