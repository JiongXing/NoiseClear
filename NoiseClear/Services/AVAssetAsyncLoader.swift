//
//  AVAssetAsyncLoader.swift
//  NoiseClear
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
    private static let timeout: TimeInterval = 30

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
        operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let resultPointer = UnsafeMutablePointer<Result<T, Error>?>.allocate(capacity: 1)
        resultPointer.initialize(to: nil)
        defer {
            resultPointer.deinitialize(count: 1)
            resultPointer.deallocate()
        }

        Task.detached(priority: .userInitiated) {
            do {
                let value = try await operation()
                lock.lock()
                resultPointer.pointee = .success(value)
                lock.unlock()
            } catch {
                lock.lock()
                resultPointer.pointee = .failure(error)
                lock.unlock()
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        guard waitResult == .success else {
            #if DEBUG
            print("[AVAssetAsyncLoader] timeout while loading \(target), timeout=\(timeout)s")
            #endif
            throw AVAssetAsyncLoaderError.timeout(target)
        }

        lock.lock()
        let result = resultPointer.pointee
        lock.unlock()

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw AVAssetAsyncLoaderError.unknown
        }
    }
}
