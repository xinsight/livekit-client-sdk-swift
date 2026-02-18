/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import Network

typealias WebSocketStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

private final class WebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: WebSocket?

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        Task { [weak self] in
            await self?.owner?.onDidOpenFromDelegate()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        Task { [weak self] in
            await self?.owner?.onDidCompleteFromDelegate(withError: error)
        }
    }
}

actor WebSocket: Loggable {
    private enum Lifecycle {
        case idle
        case connecting
        case connected
        case streaming
        case closing
        case closed
    }

    private let delegateProxy: WebSocketDelegateProxy
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask

    private var lifecycle: Lifecycle = .idle
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var streamContinuation: WebSocketStream.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var stream: WebSocketStream?

    private static func makeURLSession(delegate: URLSessionWebSocketDelegate) -> URLSession {
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        config.multipathServiceType = .handover
        #endif
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    init(url: URL, token: String, connectOptions: ConnectOptions?) {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let delegateProxy = WebSocketDelegateProxy()
        let urlSession = Self.makeURLSession(delegate: delegateProxy)
        let task = urlSession.webSocketTask(with: request)

        self.delegateProxy = delegateProxy
        self.urlSession = urlSession
        self.task = task

        delegateProxy.owner = self
    }

    func connect() async throws {
        guard lifecycle == .idle else {
            throw LiveKitError(.invalidState, message: "WebSocket is not idle")
        }

        lifecycle = .connecting
        let localTask = task
        let localSession = urlSession

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connectContinuation = continuation
                    localTask.resume()
                }
            } onCancel: {
                localTask.cancel(with: .normalClosure, reason: nil)
                localSession.finishTasksAndInvalidate()
            }
        } catch {
            if lifecycle == .connecting {
                lifecycle = .idle
            }
            throw error
        }
    }

    func setupStream() throws {
        guard lifecycle == .connected || lifecycle == .streaming else {
            throw LiveKitError(.invalidState, message: "WebSocket must be connected before setting up stream")
        }
        guard stream == nil else { return }

        stream = WebSocketStream { [weak self] continuation in
            Task { [weak self] in
                await self?.onStreamReady(continuation)
            }
        }
        lifecycle = .streaming
    }

    func streamSequence() throws -> WebSocketStream {
        guard let stream else {
            throw LiveKitError(.invalidState, message: "WebSocket stream not initialized")
        }
        return stream
    }

    func close() {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        lifecycle = .closing

        connectContinuation?.resume(throwing: LiveKitError(.cancelled))
        connectContinuation = nil
        streamContinuation?.finish(throwing: LiveKitError(.cancelled))
        streamContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil

        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        lifecycle = .closed
    }

    func send(data: Data) async throws {
        guard lifecycle == .connected || lifecycle == .streaming else {
            throw LiveKitError(.invalidState, message: "WebSocket is not connected")
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)
    }

    private func onStreamReady(_ continuation: WebSocketStream.Continuation) {
        streamContinuation = continuation
        startReceiveLoopIfNeeded()
    }

    private func startReceiveLoopIfNeeded() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while task.closeCode == .invalid, !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard let continuation = streamContinuation else { break }
                continuation.yield(message)
            } catch {
                let lkError = LiveKitError.from(error: error) ?? LiveKitError(.unknown)
                streamContinuation?.finish(throwing: lkError)
                streamContinuation = nil
                receiveTask = nil
                return
            }
        }

        receiveTask = nil
    }

    fileprivate func onDidOpenFromDelegate() {
        guard lifecycle == .connecting else { return }

        lifecycle = .connected
        connectContinuation?.resume()
        connectContinuation = nil
    }

    fileprivate func onDidCompleteFromDelegate(withError error: Error?) {
        log("didCompleteWithError: \(String(describing: error))", error != nil ? .error : .debug)

        receiveTask?.cancel()
        receiveTask = nil

        let lkError = error.map { LiveKitError.from(error: $0) ?? LiveKitError(.unknown) }
        if let connectContinuation {
            if let lkError {
                connectContinuation.resume(throwing: lkError)
            } else {
                connectContinuation.resume(throwing: LiveKitError(.network, message: "WebSocket completed before opening"))
            }
            self.connectContinuation = nil
        }

        if let lkError {
            streamContinuation?.finish(throwing: lkError)
        } else {
            streamContinuation?.finish()
        }
        streamContinuation = nil
        lifecycle = .closed
    }
}
