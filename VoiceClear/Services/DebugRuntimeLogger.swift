//
//  DebugRuntimeLogger.swift
//  VoiceClear
//

import Foundation

enum DebugRuntimeLogger {
    private static let endpoint = URL(string: "http://127.0.0.1:7245/ingest/3214dcc9-d344-4f07-8c00-92a6797aff48")

    static func log(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        let payload: [String: Any] = [
            "sessionId": "3741f6",
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let raw = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        postToCollector(raw)
    }

    private static func postToCollector(_ body: Data) {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("3741f6", forHTTPHeaderField: "X-Debug-Session-Id")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
