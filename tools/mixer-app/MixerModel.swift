import Foundation
import SwiftUI

/// State for a single mixer fader.
struct FaderState: Identifiable {
    let id: Int               // 0-9
    var clipHandle: String?
    var effectStackHandle: String?
    var volumeChannelHandle: String?
    var clipName: String = ""
    var lane: Int = 0
    var volumeDB: Double = -Double.infinity
    var volumeLinear: Double = 0
    var role: String?
    var isActive: Bool = false // has a clip assigned
    var isDragging: Bool = false // fader is being dragged

    static func inactive(index: Int) -> FaderState {
        FaderState(id: index)
    }
}

enum MixerMode: String, CaseIterable {
    case positional = "Positional"
    case roles = "Roles"
}

/// Main model driving the mixer UI. Polls SpliceKit for clip state at the playhead.
@MainActor
class MixerModel: ObservableObject {
    @Published var faders: [FaderState] = (0..<10).map { FaderState.inactive(index: $0) }
    @Published var mode: MixerMode = .positional
    @Published var isConnected = false
    @Published var lastError: String?

    let bridge = SpliceKitBridge()
    private var pollTimer: Timer?
    private var lastPlayheadSeconds: Double = -1

    func start() {
        bridge.connect()
        startPolling()
    }

    func stop() {
        stopPolling()
        bridge.disconnect()
    }

    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Polling

    private func poll() async {
        guard bridge.isConnected else {
            if isConnected {
                isConnected = false
            }
            // Try to reconnect
            bridge.connect()
            return
        }
        isConnected = true

        do {
            let result = try await bridge.call("mixer.getState")
            lastError = nil
            updateFaders(from: result)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateFaders(from result: [String: Any]) {
        guard let faderData = result["faders"] as? [[String: Any]] else { return }

        let playhead = result["playheadSeconds"] as? Double ?? 0
        lastPlayheadSeconds = playhead

        var newFaders = (0..<10).map { FaderState.inactive(index: $0) }

        for dict in faderData {
            guard let index = dict["index"] as? Int, index < 10 else { continue }

            // Don't update faders that are being dragged
            if faders[index].isDragging { continue }

            var f = FaderState(id: index)
            f.clipHandle = dict["clipHandle"] as? String
            f.effectStackHandle = dict["effectStackHandle"] as? String
            f.volumeChannelHandle = dict["volumeChannelHandle"] as? String
            f.clipName = dict["name"] as? String ?? ""
            f.lane = dict["lane"] as? Int ?? 0
            f.role = dict["role"] as? String
            f.isActive = true

            if let db = dict["volumeDB"] as? Double {
                f.volumeDB = db
            }
            if let lin = dict["volumeLinear"] as? Double {
                f.volumeLinear = lin
            }

            newFaders[index] = f
        }

        // Preserve dragging state
        for i in 0..<10 {
            if faders[i].isDragging {
                newFaders[i] = faders[i]
            }
        }

        faders = newFaders
    }

    // MARK: - Volume Control

    func beginVolumeChange(faderIndex: Int) async {
        guard faders[faderIndex].isActive,
              let esHandle = faders[faderIndex].effectStackHandle else { return }

        faders[faderIndex].isDragging = true

        do {
            _ = try await bridge.call("mixer.volumeBegin", params: [
                "effectStackHandle": esHandle
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setVolume(faderIndex: Int, db: Double) async {
        guard faders[faderIndex].isActive,
              let handle = faders[faderIndex].volumeChannelHandle else { return }

        // Update local state immediately for responsive UI
        faders[faderIndex].volumeDB = db
        faders[faderIndex].volumeLinear = db <= -144 ? 0 : pow(10.0, db / 20.0)

        do {
            _ = try await bridge.call("mixer.setVolume", params: [
                "handle": handle,
                "volumeDB": db
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func endVolumeChange(faderIndex: Int) async {
        guard let esHandle = faders[faderIndex].effectStackHandle else { return }

        faders[faderIndex].isDragging = false

        do {
            _ = try await bridge.call("mixer.volumeEnd", params: [
                "effectStackHandle": esHandle
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }
}
