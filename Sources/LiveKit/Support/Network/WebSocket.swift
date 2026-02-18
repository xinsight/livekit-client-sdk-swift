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

final class WebSocket: NSObject, @unchecked Sendable, Loggable, AsyncSequence, URLSessionWebSocketDelegate {
    typealias AsyncIterator = WebSocketStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    private let _state = StateSync(State())

    private struct State {
        var streamContinuation: WebSocketStream.Continuation?
        var connectContinuation: CheckedContinuation<Void, Error>?
        var receiveTask: Task<Void, Never>?
    }

    private let request: URLRequest
    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask!
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
        // explicitly set timeout intervals
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        /// https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        config.multipathServiceType = .handover
        #endif
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    init(url: URL, token: String, connectOptions: ConnectOptions?) {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        self.request = request

        super.init()
        urlSession = Self.makeURLSession(delegate: self)
        task = urlSession.webSocketTask(with: request)
    }

    func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                _state.mutate { state in
                    state.connectContinuation = continuation
                }
                task.resume()
            }
        } onCancel: {
            close()
        }
    }

    func setupStream() {
        guard stream == nil else { return }
        stream = WebSocketStream { [weak self] continuation in
            guard let self else { return }
            _state.mutate { state in
                state.streamContinuation = continuation
            }
            startReceiveLoopIfNeeded()
        }
    }

    deinit {
        close()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()

        let (connectContinuation, streamContinuation, receiveTask) = _state.mutate { state in
            let connectContinuation = state.connectContinuation
            let streamContinuation = state.streamContinuation
            let receiveTask = state.receiveTask
            state.connectContinuation = nil
            state.streamContinuation = nil
            state.receiveTask = nil
            return (connectContinuation, streamContinuation, receiveTask)
        }

        receiveTask?.cancel()
        connectContinuation?.resume(throwing: LiveKitError(.cancelled))
        streamContinuation?.finish(throwing: LiveKitError(.cancelled))
    }

    // MARK: - AsyncSequence

    func makeAsyncIterator() -> AsyncIterator {
        guard let stream else {
            return WebSocketStream { continuation in
                continuation.finish(throwing: LiveKitError(.invalidState, message: "WebSocket stream not initialized"))
            }.makeAsyncIterator()
        }
        return stream.makeAsyncIterator()
    }

    private func startReceiveLoopIfNeeded() {
        _state.mutate { state in
            guard state.receiveTask == nil else { return }
            state.receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        }
    }

    private func receiveLoop() async {
        while task.closeCode == .invalid, !Task.isCancelled {
            do {
                let message = try await task.receive()

                guard let continuation = _state.read({ $0.streamContinuation }) else {
                    _state.mutate { $0.receiveTask = nil }
                    return
                }
                continuation.yield(message)
            } catch {
                let lkError = LiveKitError.from(error: error) ?? LiveKitError(.unknown)
                let continuation = _state.mutate { state in
                    let continuation = state.streamContinuation
                    state.streamContinuation = nil
                    state.receiveTask = nil
                    return continuation
                }
                continuation?.finish(throwing: lkError)
                return
            }
        }

        _state.mutate { $0.receiveTask = nil }
    }

    // MARK: - Send

    func send(data: Data) async throws {
        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        let continuation = _state.mutate { state in
            let continuation = state.connectContinuation
            state.connectContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        log("didCompleteWithError: \(String(describing: error))", error != nil ? .error : .debug)

        let (connectContinuation, streamContinuation, receiveTask, lkError) = _state.mutate { state in
            let connectContinuation = state.connectContinuation
            let streamContinuation = state.streamContinuation
            let receiveTask = state.receiveTask
            let lkError = error.map { LiveKitError.from(error: $0) ?? LiveKitError(.unknown) }
            state.connectContinuation = nil
            state.streamContinuation = nil
            state.receiveTask = nil
            return (connectContinuation, streamContinuation, receiveTask, lkError)
        }

        receiveTask?.cancel()
        if let lkError {
            connectContinuation?.resume(throwing: lkError)
            streamContinuation?.finish(throwing: lkError)
        } else {
            connectContinuation?.resume()
            streamContinuation?.finish()
        }
    }
}
