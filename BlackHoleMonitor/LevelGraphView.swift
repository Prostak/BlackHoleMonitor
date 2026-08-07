import SwiftUI

struct LevelGraphView: View {
    let samples: [Float]
    let thresholdRMS: Float
    let maxRMS: Float

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawGrid(in: size, context: &context)
                drawThreshold(in: size, context: &context)
                drawWaveform(in: size, context: &context)
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func drawGrid(in size: CGSize, context: inout GraphicsContext) {
        let gridColor = Color.white.opacity(0.08)
        let step = maxRMS / 6
        let lines = (0...6).map { Float($0) * step }

        for value in lines {
            let y = yPosition(for: value, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func drawThreshold(in size: CGSize, context: inout GraphicsContext) {
        let y = yPosition(for: thresholdRMS, height: size.height)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(.red.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
    }

    private func drawWaveform(in size: CGSize, context: inout GraphicsContext) {
        guard samples.count > 1 else { return }

        var path = Path()
        let stepX = size.width / CGFloat(max(samples.count - 1, 1))

        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * stepX
            let y = yPosition(for: sample, height: size.height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [.green, .yellow, .orange, .red]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            ),
            lineWidth: 2
        )

        if let last = samples.last {
            let x = size.width
            let y = yPosition(for: last, height: size.height)
            let dot = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
        }
    }

    private func yPosition(for rms: Float, height: CGFloat) -> CGFloat {
        let clamped = max(0, min(maxRMS, rms))
        let normalized = clamped / maxRMS
        return height * (1 - CGFloat(normalized))
    }
}

struct LevelMeterView: View {
    let levelRMS: Float
    let peakRMS: Float
    let thresholdRMS: Float
    let maxRMS: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(levelGradient)
                    .frame(width: geometry.size.width * levelFraction)

                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: geometry.size.height)
                    .offset(x: geometry.size.width * peakFraction - 1)

                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 2, height: geometry.size.height)
                    .offset(x: geometry.size.width * thresholdFraction - 1)
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var levelFraction: CGFloat {
        CGFloat(min(levelRMS / maxRMS, 1))
    }

    private var peakFraction: CGFloat {
        CGFloat(min(peakRMS / maxRMS, 1))
    }

    private var thresholdFraction: CGFloat {
        CGFloat(min(thresholdRMS / maxRMS, 1))
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .orange, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct ThresholdSliderView: View {
    @Binding var thresholdRMS: Float
    let maxRMS: Float

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.2f%%", thresholdRMS * 100))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.red.opacity(0.9))

            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.red.opacity(0.25))
                        .frame(height: geometry.size.height * normalizedThreshold)

                    Circle()
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                        }
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height * (1 - normalizedThreshold)
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            thresholdRMS = rms(for: value.location.y, height: geometry.size.height)
                        }
                )
            }

            Text(String(format: "Scale %.2f%%", maxRMS * 100))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }

    private var normalizedThreshold: CGFloat {
        CGFloat(min(max(thresholdRMS / maxRMS, 0), 1))
    }

    private func rms(for y: CGFloat, height: CGFloat) -> Float {
        let normalized = 1 - Float(y / max(height, 1))
        let clamped = min(max(normalized, 0), 1) * maxRMS
        return max(clamped, AudioLevelMonitor.minimumTriggerRMS)
    }
}
