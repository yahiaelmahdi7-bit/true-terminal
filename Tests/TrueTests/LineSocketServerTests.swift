import Testing
import Foundation
@testable import True

/// A stopped server must never answer a newer server's clients, even when the newer socket reuses its fd number.
@Suite struct LineSocketServerTests {
    @Test func stoppedServerNeverAnswersTheNextOnesClients() {
        for _ in 0..<20 {
            let pa = tempSock(), pb = tempSock()
            let a = LineSocketServer(path: pa) { _, reply in reply(Data("A\n".utf8)) }
            #expect(a.start())
            #expect(ask(pa) == "A\n")   // a's loop has accepted once and gone back to accept()
            a.stop()
            let b = LineSocketServer(path: pb) { _, reply in reply(Data("B\n".utf8)) }
            #expect(b.start())
            for _ in 0..<10 { #expect(ask(pb) == "B\n") }
            b.stop()
        }
    }

    @Test func stoppedServerRefusesNewClients() {
        let p = tempSock()
        let s = LineSocketServer(path: p) { _, reply in reply(Data("x\n".utf8)) }
        #expect(s.start())
        s.stop()
        #expect(ask(p) == "connect failed")
    }
}

private func tempSock() -> String { "/tmp/ls-\(UUID().uuidString.prefix(8)).sock" }

private func ask(_ sock: String) -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        _ = sock.utf8CString.withUnsafeBytes { memcpy(dst.baseAddress, $0.baseAddress, min($0.count, dst.count)) }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return "connect failed" }
    _ = write(fd, "hi\n", 3)
    var got = [UInt8](), buf = [UInt8](repeating: 0, count: 256)
    while !got.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        got += buf[0..<n]
    }
    return String(decoding: got, as: UTF8.self)
}
