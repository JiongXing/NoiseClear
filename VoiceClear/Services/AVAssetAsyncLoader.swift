//
//  AVAssetAsyncLoader.swift
//  VoiceClear
//
//  Compatibility wrappers for iOS 16+ async AVAsset loading APIs.
//

import AVFoundation
import Foundation

enum AVAssetAsyncLoaderError: LocalizedError {
    case timeout(String)
    case noTrack(AVMediaType)
    case unknown

    var errorDescription: String? {
        switch self {
        case .timeout(let target):
            return L10n.string(.serviceErrorAsyncLoadTimeout, target)
        case .noTrack(let type):
            return L10n.string(.serviceErrorNoMediaTrack, type.rawValue)
        case .unknown:
            return L10n.string(.serviceErrorMediaLoadFailed)
        }
    }
}

enum AVAssetAsyncLoader {
    private static let timeout: TimeInterval = 10

    static func firstTrack(of asset: AVAsset, mediaType: AVMediaType) throws -> AVAssetTrack {
        let tracks = try blockingLoad("tracks(\(mediaType.rawValue))") {
            try await asset.loadTracks(withMediaType: mediaType)
        }
        guard let track = tracks.first else {
            throw AVAssetAsyncLoaderError.noTrack(mediaType)
        }
        return track
    }

    static func durationSeconds(of asset: AVAsset) throws -> TimeInterval {
        let duration = try blockingLoad("duration") {
            try await asset.load(.duration)
        }
        return CMTimeGetSeconds(duration)
    }

    static func firstFormatDescription(of track: AVAssetTrack) throws -> CMFormatDescription? {
        let descriptions = try blockingLoad("formatDescriptions") {
            try await track.load(.formatDescriptions)
        }
        return descriptions.first
    }

    private static func blockingLoad<T>(
        _ target: String,
        operation: @escaping () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<T, Error>?
        Task {
            do {
                let value = try await operation()
                output = .success(value)
            } catch {
                output = .failure(error)
            }
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        guard waitResult == .success else {
            throw AVAssetAsyncLoaderError.timeout(target)
        }
        switch output {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw AVAssetAsyncLoaderError.unknown
        }
    }
}
