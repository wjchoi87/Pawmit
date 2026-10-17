import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UnixSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)
    case closed
    case timeout
    case messageTooLarge

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "socket path too long: \(p)"
        case .syscall(let name, let err): return "\(name) failed: \(String(cString: strerror(err)))"
        case .closed: return "connection closed"
        case .timeout: return "timed out"
        case .messageTooLarge: return "message too large"
        }
    }
}

enum SocketAddress {
    static func make(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// 블로킹 Unix socket 클라이언트. hook CLI처럼 짧게 살다 죽는 프로세스용.
public final class UnixSocketClient {
    private var fd: Int32 = -1
    private var buffer = Data()

    public init() {}

    deinit { close() }

    public func connect(path: String) throws {
        signal(SIGPIPE, SIG_IGN)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.syscall("socket", errno) }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var addr = try SocketAddress.make(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let err = errno
            close()
            throw UnixSocketError.syscall("connect", err)
        }
    }

    public func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.syscall("write", errno)
                }
                offset += n
            }
        }
    }

    /// "\n"까지 한 줄 읽기. timeout이 nil이면 무한 대기. EOF면 `.closed`.
    public func readLine(timeout: TimeInterval?) throws -> Data {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                return Data(line)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            var waitMs: Int32 = -1
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw UnixSocketError.timeout }
                waitMs = Int32(min(remaining * 1000, Double(Int32.max)))
            }
            let pr = poll(&pfd, 1, waitMs)
            if pr < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.syscall("poll", errno)
            }
            if pr == 0 { throw UnixSocketError.timeout }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw UnixSocketError.syscall("read", errno)
            }
            if n == 0 { throw UnixSocketError.closed }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > Wire.maxMessageBytes { throw UnixSocketError.messageTooLarge }
        }
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

/// 앱 쪽 연결 하나. 요청 한 줄을 받으면 `onMessage`, 상대가 끊으면 `onClose`.
/// 응답 대기 중인 hook 프로세스가 죽으면(사용자가 터미널에서 먼저 답한 경우 등) `onClose`로 말풍선을 정리한다.
public final class UnixSocketConnection: @unchecked Sendable {
    public let id = UUID()
    public let peerUID: uid_t
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    private var delivered = false

    public var onMessage: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 { uid = uid_t.max }
        self.peerUID = uid
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > Wire.maxMessageBytes { close(); return }
                continue
            }
            if n == 0 { close(); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            close(); return
        }
        if !delivered, let idx = buffer.firstIndex(of: 0x0A) {
            delivered = true
            let line = Data(buffer[buffer.startIndex..<idx])
            buffer.removeAll()
            onMessage?(line)
        }
    }

    /// 응답 한 줄 쓰고 연결을 닫는다. 이미 닫혔으면 false.
    /// socket queue 안(onMessage 콜백 등)에서 불려도 deadlock 나지 않게 실행
    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: UnixSocketServer.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    @discardableResult
    public func reply(_ data: Data) -> Bool {
        var ok = false
        onQueue {
            guard !closed else { return }
            ok = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, base + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN {
                            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&pfd, 1, 1000)
                            continue
                        }
                        return false
                    }
                    offset += n
                }
                return true
            }
        }
        close()
        return ok
    }

    public func close() {
        let run = {
            guard !self.closed else { return }
            self.closed = true
            self.source?.cancel()
            self.source = nil
            let cb = self.onClose
            self.onClose = nil
            self.onMessage = nil
            cb?()
        }
        onQueue(run)
    }

    public var isClosed: Bool {
        var value = false
        onQueue { value = closed }
        return value
    }
}

/// 앱 쪽 Unix socket 서버. socket 파일은 0600, 접속한 프로세스의 uid가 현재 사용자와 다르면 즉시 끊는다.
public final class UnixSocketServer: @unchecked Sendable {
    static let queueKey = DispatchSpecificKey<Bool>()

    public let path: String
    private let queue = DispatchQueue(label: "pawmit.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UUID: UnixSocketConnection] = [:]

    /// 새 연결마다 호출 (socket queue에서). 핸들러가 onMessage/onClose를 설정한다.
    public var onConnection: ((UnixSocketConnection) -> Void)?

    public init(path: String) {
        self.path = path
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    /// 다른 Pawmit 인스턴스가 이미 socket을 듣고 있는지 확인.
    public static func isServing(path: String) -> Bool {
        let client = UnixSocketClient()
        defer { client.close() }
        return (try? client.connect(path: path)) != nil
    }

    public func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw UnixSocketError.syscall("socket", errno) }
        var addr = try SocketAddress.make(path)
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0 else {
            let err = errno
            Darwin.close(listenFD)
            throw UnixSocketError.syscall("bind", err)
        }
        chmod(path, 0o600)
        guard listen(listenFD, 32) == 0 else { throw UnixSocketError.syscall("listen", errno) }
        let flags = fcntl(listenFD, F_GETFL)
        _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { [listenFD] in Darwin.close(listenFD) }
        acceptSource = src
        src.resume()
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            let conn = UnixSocketConnection(fd: fd, queue: queue)
            guard conn.peerUID == getuid() else {
                conn.close()
                continue
            }
            connections[conn.id] = conn
            let previousClose = conn.onClose
            onConnection?(conn)
            let handlerClose = conn.onClose
            conn.onClose = { [weak self, id = conn.id] in
                previousClose?()
                handlerClose?()
                self?.connections.removeValue(forKey: id)
            }
            conn.start()
        }
    }

    public func stop() {
        let work = {
            self.acceptSource?.cancel()
            self.acceptSource = nil
            for c in self.connections.values { c.close() }
            self.connections.removeAll()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
        unlink(path)
    }
}
