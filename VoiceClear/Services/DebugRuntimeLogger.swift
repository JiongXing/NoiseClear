//
//  DebugRuntimeLogger.swift
//  VoiceClear
//

import Foundation

enum DebugRuntimeLogger {
    private static let endpoint = "http://127.0.0.1:7245/ingest/3214dcc9-d344-4f07-8c00-92a6797aff48"
    private static let sessionId = "05c3c3"

    static func log(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        payload["id"] = "log_\(payload["timestamp"] ?? 0)_\(UUID().uuidString.prefix(8))"
        guard let url = URL(string: endpoint),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionId, forHTTPHeaderField: "X-Debug-Session-Id")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}

