import XCTest
@testable import PawmitCore

final class SocketTests: XCTestCase {
    func tempSocket() -> String {
        "/tmp/pawmit-\(UUID().uuidString.prefix(8)).sock"
    }

    func testRoundTripReply() throws {
        let path = tempSocket()
        let server = UnixSocketServer(path: path)
        defer { server.stop() }
        server.onConnection = { conn in
            conn.onMessage = { line in
                let env = try! WireCodec.decode(HookEnvelope.self, line: line)
                conn.reply(try! WireCodec.encodeLine(HookReply(id: env.id, decision: .allow)))
            }
        }
        try server.start()
        XCTAssertTrue(UnixSocketServer.isServing(path: path))

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let env = HookEnvelope(agent: "claude", event: "PermissionRequest", expectsReply: true, pid: 1, ppid: 1, tty: nil,
                               env: [:], cwd: nil, payload: ["tool_name": "Bash"], waitSeconds: 5)
        let client = UnixSocketClient()
        try client.connect(path: path)
        try client.send(try WireCodec.encodeLine(env))
        let reply = try WireCodec.decode(HookReply.self, line: try client.readLine(timeout: 5))
        XCTAssertEqual(reply.id, env.id)
        XCTAssertEqual(reply.decision, .allow)
    }

    func testServerSeesClientDisconnect() throws {
        let path = tempSocket()
        let server = UnixSocketServer(path: path)
        defer { server.stop() }
        let closed = expectation(description: "closed")
        let received = expectation(description: "received")
        server.onConnection = { conn in
            conn.onMessage = { _ in received.fulfill() }
            conn.onClose = { closed.fulfill() }
        }
        try server.start()
        let client = UnixSocketClient()
        try client.connect(path: path)
        try client.send(Data("{\"x\":1}\n".utf8))
        wait(for: [received], timeout: 3)
        // hook 프로세스가 죽은 상황 (사용자가 터미널에서 먼저 답함)
        client.close()
        wait(for: [closed], timeout: 3)
    }

    func testClientFailsFastWhenAppIsOff() {
        let client = UnixSocketClient()
        XCTAssertThrowsError(try client.connect(path: tempSocket()))
    }
}
