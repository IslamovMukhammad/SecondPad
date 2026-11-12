import Foundation

/// Minimal HTTP/1.1 request parsing: request line, headers, `Content-Length` body. Unit-tested.
/// Used by both the hook socket and the tablet web server.
nonisolated struct HTTPRequest: Equatable, Sendable {
    let method: String
    /// The path without the query string.
    let path: String
    var query: [String: String] = [:]
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
    /// Bytes this request used from the buffer (head + body).
    var length = 0

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum Parse: Equatable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
        case tooLarge
    }

    static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHeaderBytes else { return .tooLarge }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid }
            guard value <= maxBodyBytes else { return .tooLarge }
            length = value
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        let target = String(requestLine[1])
        let (path, query) = splitTarget(target)
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, query: query,
                                     headers: headers, body: body,
                                     length: bodyStart + length - data.startIndex))
    }

    /// "/appicon?id=com.x" → ("/appicon", ["id": "com.x"])
    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            query[key] = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
        }
        return (String(target[..<mark]), query)
    }
}
