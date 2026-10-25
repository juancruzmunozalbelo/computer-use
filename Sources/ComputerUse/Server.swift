import Foundation

typealias RPCHandler = ([String: Any]) throws -> Any

enum RPCError: Error {
    case badRequest(String)
    case methodNotFound(String)

    var message: String {
        switch self {
        case .badRequest(let m): return m
        case .methodNotFound(let m): return "Method not found: \(m)"
        }
    }
}

final class BridgeServer {
    private var handlers: [String: RPCHandler] = [:]
    let port: UInt16

    init(port: UInt16) { self.port = port }

    func register(_ method: String, _ handler: @escaping RPCHandler) {
        handlers[method] = handler
    }

    func run() -> Never {
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { fatalError("socket() failed") }
        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(serverFD, 8) == 0 else {
            fatalError("bind/listen failed on 127.0.0.1:\(port)")
        }
        writeDiscovery()
        FileHandle.standardError.write("computer-use listening on 127.0.0.1:\(port)\n".data(using: .utf8)!)

        while true {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let conn = accept(serverFD, &clientAddr, &len)
            if conn < 0 { continue }
            handleConnection(conn)
            close(conn)
        }
    }

    private func writeDiscovery() {
        let meta: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "port": Int(port),
            "host": "127.0.0.1",
            "status": "ready",
            "started_at": Date().timeIntervalSince1970,
        ]
        let tmp = "/tmp/computer_use_bridge.json.tmp"
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.moveItem(atPath: tmp, toPath: "/tmp/computer_use_bridge.json")
        }
    }

    private func handleConnection(_ conn: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        readLoop: while true {
            let n = chunk.withUnsafeMutableBytes { recv(conn, $0.baseAddress, 8192, 0) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 16 * 1024 * 1024 { return }
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if line.isEmpty { continue }
                let resp = dispatch(line)
                if let out = try? JSONSerialization.data(withJSONObject: resp) {
                    var framed = out
                    framed.append(0x0a)
                    framed.withUnsafeBytes { _ = send(conn, $0.baseAddress, framed.count, 0) }
                }
                if buffer.count > 16 * 1024 * 1024 { break readLoop }
            }
        }
    }

    private func dispatch(_ line: Data) -> [String: Any] {
        guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return ["jsonrpc": "2.0", "id": NSNull(),
                    "error": ["code": -32700, "message": "Parse error"]]
        }
        let id = req["id"] ?? NSNull()
        guard let method = req["method"] as? String else {
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32600, "message": "Invalid Request"]]
        }
        let params = (req["params"] as? [String: Any]) ?? [:]
        guard let handler = handlers[method] else {
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
        do {
            let result = try handler(params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32602, "message": e.message]]
        } catch {
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32603, "message": "\(error)"]]
        }
    }
}
