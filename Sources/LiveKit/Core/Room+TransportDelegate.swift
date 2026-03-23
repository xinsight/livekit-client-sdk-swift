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

internal import LiveKitWebRTC

@inline(__always)
private func assertNotMainThread(_ context: String) {
    dispatchPrecondition(condition: .notOnQueue(.main))
}

extension LKRTCPeerConnectionState {
    var isConnected: Bool {
        self == .connected
    }

    var isDisconnected: Bool {
        [.disconnected, .failed].contains(self)
    }
}

extension Room: TransportDelegate {
    func transport(_ transport: Transport, didUpdateState pcState: LKRTCPeerConnectionState) {
        assertNotMainThread("Room.transport.didUpdateState")
        log("target: \(transport.target), connectionState: \(pcState.description)")

        // primary connected
        if transport.isPrimary {
            if pcState.isConnected {
                primaryTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                primaryTransportConnectedCompleter.reset()
            }
        }

        // publisher connected
        if case .publisher = transport.target {
            if pcState.isConnected {
                publisherTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                publisherTransportConnectedCompleter.reset()
            }
        }

        if _state.connectionState == .connected {
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), pcState.isDisconnected {
                Task {
                    assertNotMainThread("Room.transport.didUpdateState.startReconnectTask")
                    do {
                        try await startReconnect(reason: .transport)
                    } catch {
                        log("Failed calling startReconnect, error: \(error)", .error)
                    }
                }
            }
        }
    }

    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: IceCandidate) {
        Task {
            assertNotMainThread("Room.transport.didGenerateIceCandidate.task")
            guard _state.connectionState != .disconnected else {
                log("Dropping ICE candidate while room is disconnected", .debug)
                return
            }

            let signalState = await signalClient.connectionState
            guard signalState != .disconnected else {
                log("Dropping ICE candidate while signal client is disconnected", .debug)
                return
            }

            do {
                log("sending iceCandidate")
                try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
            } catch let error as LiveKitError where error.type == .invalidState {
                // Expected when signaling disconnects during negotiation.
                log("Dropping ICE candidate due to signaling state: \(error)", .debug)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == 57 {
                // Expected socket-closed race during reconnect/cleanup.
                log("Dropping ICE candidate after socket close: \(error)", .debug)
            } catch {
                log("Failed to send iceCandidate, error: \(error)", .error)
            }
        }
    }

    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        if transport.target == .subscriber {
            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected })
            { [weak self] in
                guard let self else { return }
                Task {
                    assertNotMainThread("Room.transport.didAddTrack.task")
                    await self.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, stream: streams.first!)
                }
            }
        }
    }

    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) {
        if transport.target == .subscriber {
            Task {
                assertNotMainThread("Room.transport.didRemoveTrack.task")
                await engine(self, didRemoveTrack: track)
            }
        }
    }

    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        if _state.isSubscriberPrimary, transport.target == .subscriber {
            switch dataChannel.label {
            case LKRTCDataChannel.Labels.reliable: subscriberDataChannel.set(reliable: dataChannel)
            case LKRTCDataChannel.Labels.lossy: subscriberDataChannel.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    func transportShouldNegotiate(_: Transport) {}
}
