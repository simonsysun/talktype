import Foundation

/// Appends to `~/.talktype/talktype.log` as well as stdout.
///
/// Launched from Finder there is nowhere for `print` to go, so anything worth diagnosing
/// after the fact has to reach a file — otherwise the only way to see what the app did is
/// to run it from a terminal, which is not how it is used.
enum Log {

    private static let queue = DispatchQueue(label: "dev.talktype.log")
    private static let maxBytes = 512 * 1024        // keep it small; it is a tail, not an archive

    static var fileURL: URL { AppIdentity.stateDir.appendingPathComponent("talktype.log") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        print(message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                // Keep the newest half rather than deleting: the interesting events are
                // usually the ones just before someone notices a problem.
                if let data = try? Data(contentsOf: url) {
                    try? data.suffix(maxBytes / 2).write(to: url)
                }
            }

            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
