import Foundation

/// Keeps XCTest from sleeping through a tenth of a second after every async
/// `setUp`, test and `tearDown` in this bundle.
///
/// XCTest runs an async fixture or test as a task and waits for it on the
/// main thread, by running the main run loop in slices of up to 0.1 s
/// (`+[XCTWaiter _synchronouslyWaitForTimeInterval:]`, which calls
/// `CFRunLoopRunInMode` with `returnAfterSourceHandled` set). A slice ends
/// early only when the run loop handles a source. The task's own work on the
/// main actor is not one, and neither is a timer, so in the idle host app a
/// fixture that finished in microseconds was still waited on for the rest of
/// its slice: 0.1 s for each async `setUp`, test body and `tearDown`. The
/// suites here override their fixtures asynchronously on purpose
/// (`TestBundleIsolationScanTests`), so that was about 0.2 s for most of the
/// bundle's tests, and more than half the time the whole suite took (298 s
/// without this, 140 s with it, same machine and build).
///
/// This signals a run-loop source that does nothing, a thousand times a
/// second, which ends each slice within a millisecond and has XCTest look
/// again at whether the task is done. It changes when XCTest notices a
/// finished task, never what a test sees: the run loop already ran for the
/// whole wait.
///
/// It is the bundle's principal class (`NSPrincipalClass`, set for
/// `CabalmailMacTests` in `project.yml`), which XCTest makes one of on the
/// main thread when it loads the bundle, before any test runs.
@objc(TestRunLoopKeepAwake)
final class TestRunLoopKeepAwake: NSObject {
    private struct Source: @unchecked Sendable {
        let ref: CFRunLoopSource
    }

    override init() {
        super.init()
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        let source = Source(ref: CFRunLoopSourceCreate(nil, 0, &context))
        CFRunLoopAddSource(CFRunLoopGetMain(), source.ref, .commonModes)
        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
            CFRunLoopSourceSignal(source.ref)
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
