import SwiftUI

/// dB tick marks for the fader scale.
private let dbTicks: [(Double, String)] = [
    (12, "+12"),
    (6, "+6"),
    (0, "0"),
    (-3, "-3"),
    (-6, "-6"),
    (-12, "-12"),
    (-24, "-24"),
    (-48, "-48"),
    (-96, "-inf"),
]

/// Convert dB to a 0...1 fader position using a perceptual curve.
/// Maps -96 dB -> 0.0, 0 dB -> 0.75, +12 dB -> 1.0
func dbToFaderPosition(_ db: Double) -> Double {
    if db <= -96 { return 0 }
    if db >= 12 { return 1 }
    if db >= 0 {
        // 0 to +12 maps to 0.75 to 1.0
        return 0.75 + (db / 12.0) * 0.25
    } else {
        // -96 to 0 maps to 0.0 to 0.75
        // Use a log-like curve for better low-end resolution
        let normalized = (db + 96) / 96 // 0..1
        return pow(normalized, 0.5) * 0.75
    }
}

/// Convert a 0...1 fader position back to dB.
func faderPositionToDB(_ pos: Double) -> Double {
    if pos <= 0 { return -96 }
    if pos >= 1 { return 12 }
    if pos >= 0.75 {
        // 0.75 to 1.0 -> 0 to +12
        return ((pos - 0.75) / 0.25) * 12
    } else {
        // 0.0 to 0.75 -> -96 to 0
        let normalized = pos / 0.75
        return pow(normalized, 2.0) * 96 - 96
    }
}

/// A single vertical fader for one mixer channel.
struct FaderView: View {
    let fader: FaderState
    let onDragStart: () -> Void
    let onDragChange: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var faderPosition: Double = 0

    private let faderWidth: CGFloat = 60
    private let faderHeight: CGFloat = 280
    private let trackWidth: CGFloat = 4
    private let thumbHeight: CGFloat = 24
    private let thumbWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 4) {
            // dB value display
            Text(dbString)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(fader.isActive ? .primary : .secondary)
                .frame(height: 14)

            // Fader track + thumb
            ZStack(alignment: .bottom) {
                // Tick marks
                GeometryReader { geo in
                    ForEach(dbTicks, id: \.0) { db, label in
                        let pos = dbToFaderPosition(db)
                        let y = geo.size.height * (1 - pos)
                        HStack(spacing: 2) {
                            Text(label)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 1)
                        }
                        .position(x: 18, y: y)
                    }
                }
                .frame(width: faderWidth)

                // Track groove
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: trackWidth, height: faderHeight)

                // Level fill
                GeometryReader { geo in
                    let fillHeight = geo.size.height * faderPosition
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(levelGradient)
                            .frame(width: trackWidth, height: fillHeight)
                    }
                }
                .frame(width: trackWidth, height: faderHeight)

                // Thumb
                GeometryReader { geo in
                    let y = geo.size.height * (1 - faderPosition) - thumbHeight / 2
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fader.isActive ? Color.accentColor : Color.gray.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(
                            // Grip lines
                            VStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Rectangle()
                                        .fill(Color.white.opacity(0.4))
                                        .frame(width: 20, height: 1)
                                }
                            }
                        )
                        .frame(width: thumbWidth, height: thumbHeight)
                        .position(x: geo.size.width / 2, y: y + thumbHeight / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !fader.isDragging {
                                        onDragStart()
                                    }
                                    let newY = value.location.y
                                    let newPos = max(0, min(1, 1 - newY / geo.size.height))
                                    faderPosition = newPos
                                    onDragChange(faderPositionToDB(newPos))
                                }
                                .onEnded { _ in
                                    onDragEnd()
                                }
                        )
                }
                .frame(width: faderWidth, height: faderHeight)
            }
            .frame(width: faderWidth, height: faderHeight)

            // Lane indicator
            Text("L\(fader.lane)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(height: 12)

            // Role badge
            if let role = fader.role {
                Text(role)
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(roleColor(role).opacity(0.3))
                    .cornerRadius(3)
                    .lineLimit(1)
            } else {
                Text("")
                    .font(.system(size: 8))
                    .frame(height: 14)
            }

            // Clip name
            Text(fader.isActive ? fader.clipName : "--")
                .font(.system(size: 9))
                .foregroundStyle(fader.isActive ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: faderWidth, height: 24)

            // Fader number
            Text("\(fader.id + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: faderWidth + 8)
        .padding(.vertical, 4)
        .onChange(of: fader.volumeDB) {
            if !fader.isDragging {
                faderPosition = dbToFaderPosition(fader.volumeDB)
            }
        }
        .onAppear {
            faderPosition = dbToFaderPosition(fader.volumeDB)
        }
    }

    private var dbString: String {
        guard fader.isActive else { return "--" }
        if fader.volumeDB <= -96 { return "-inf" }
        return String(format: "%.1f", fader.volumeDB)
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .red],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func roleColor(_ role: String) -> Color {
        switch role.lowercased() {
        case "dialogue": return .blue
        case "music": return .purple
        case "effects": return .orange
        default: return .gray
        }
    }
}
