import Foundation
import PawmitCore

/// `~/.pawmit/pawmit.log` 에 남기는 간단한 로그. 민감정보(명령 원문 등)는 남기지 않는다.
enum Log {
    private static let queue = DispatchQueue(label: "pawmit.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = PawmitPaths.log
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        #if DEBUG
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }
}
