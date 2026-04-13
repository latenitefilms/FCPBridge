import SwiftUI

/// Main mixer view with 10 horizontal faders.
struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Connection status
                Circle()
                    .fill(model.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("SpliceKit Mixer")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // Mode picker
                Picker("Mode", selection: $model.mode) {
                    ForEach(MixerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Error banner
            if let error = model.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") {
                        model.lastError = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.1))
            }

            // Faders
            HStack(spacing: 0) {
                ForEach(model.faders) { fader in
                    FaderView(
                        fader: fader,
                        onDragStart: {
                            Task {
                                await model.beginVolumeChange(faderIndex: fader.id)
                            }
                        },
                        onDragChange: { db in
                            Task {
                                await model.setVolume(faderIndex: fader.id, db: db)
                            }
                        },
                        onDragEnd: {
                            Task {
                                await model.endVolumeChange(faderIndex: fader.id)
                            }
                        }
                    )

                    if fader.id < 9 {
                        Divider()
                            .frame(height: 340)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
