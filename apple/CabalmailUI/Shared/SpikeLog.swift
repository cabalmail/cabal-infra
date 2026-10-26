import Foundation

/// Decision 9 spike only (throwaway branch): one line per event, with the
/// system uptime, appended to Documents/spike.log in the app's container and
/// printed. Read it with `simctl get_app_container <udid>
/// com.cabalmail.Cabalmail data`.
enum SpikeLog {
    private static let queue = DispatchQueue(label: "com.cabalmail.spike-log")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("spike.log")
    }()

    static func note(_ message: @autoclosure () -> String) {
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + message() + "\n"
        print("[spike] " + line, terminator: "")
        let url = url
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func id(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }
}
