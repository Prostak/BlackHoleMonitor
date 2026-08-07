import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: AudioLevelMonitor

    private var triggerPercent: Float {
        AudioLevelMonitor.triggerThresholdRMS * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            levelReadout
            LevelMeterView(
                levelRMS: monitor.levelRMS,
                peakRMS: monitor.peakRMS,
                thresholdRMS: AudioLevelMonitor.triggerThresholdRMS
            )
            LevelGraphView(
                samples: monitor.levelHistory,
                thresholdRMS: AudioLevelMonitor.triggerThresholdRMS
            )
            .frame(height: 180)

            HStack {
                statusIndicator
                Spacer()
                if !monitor.permissionGranted {
                    Button("Open Settings") {
                        monitor.openSystemSettings()
                    }
                }
                Button(monitor.isRunning ? "Stop" : "Start") {
                    if monitor.isRunning {
                        monitor.stopMonitoring()
                    } else {
                        monitor.requestPermissionAndStart()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.08, green: 0.09, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .onAppear {
            monitor.requestPermissionAndStart()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BlackHole Monitor")
                .font(.title2.weight(.semibold))
            Text("Input: \(monitor.selectedDeviceName ?? AudioLevelMonitor.targetDeviceName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(
                format: "Trigger at %.1f dB (%.2f%% amplitude) → Screen Sharing",
                AudioLevelMonitor.triggerThresholdDB,
                triggerPercent
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var levelReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Level")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatAmplitude(monitor.levelRMS))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(for: monitor.levelRMS))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Peak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatAmplitude(monitor.peakRMS))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(for: monitor.peakRMS))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("RMS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatRaw(monitor.levelRMS))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.isRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(monitor.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatAmplitude(_ rms: Float) -> String {
        if rms < 0.000_1 {
            return "0.0%"
        }
        return String(format: "%.2f%%", rms * 100)
    }

    private func formatRaw(_ rms: Float) -> String {
        String(format: "%.5f", rms)
    }

    private func color(for rms: Float) -> Color {
        let threshold = AudioLevelMonitor.triggerThresholdRMS
        if rms >= threshold {
            return .red
        }
        if rms >= threshold * 0.7 {
            return .orange
        }
        if rms >= threshold * 0.4 {
            return .yellow
        }
        return .green
    }
}

#Preview {
    ContentView(monitor: AudioLevelMonitor())
        .frame(width: 520, height: 360)
}
