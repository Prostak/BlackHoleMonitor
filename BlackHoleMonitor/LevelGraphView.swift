import SwiftUI

struct LevelGraphView: View {
    let samples: [Float]
    let thresholdRMS: Float
    let maxRMS: Float = 0.12

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
        let lines: [Float] = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.12]

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
    let maxRMS: Float = 0.12

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
