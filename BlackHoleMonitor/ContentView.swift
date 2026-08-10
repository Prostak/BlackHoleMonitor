import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: AudioLevelMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputControls
            levelReadout
            LevelMeterView(
                levelRMS: monitor.levelRMS,
                peakRMS: monitor.peakRMS,
                thresholdRMS: monitor.triggerThresholdRMS,
                maxRMS: monitor.graphMaxRMS
            )
            HStack(alignment: .top, spacing: 8) {
                LevelGraphView(
                    samples: monitor.levelHistory,
                    thresholdRMS: monitor.triggerThresholdRMS,
                    maxRMS: monitor.graphMaxRMS
                )
                ThresholdSliderView(
                    thresholdRMS: $monitor.triggerThresholdRMS,
                    maxRMS: monitor.graphMaxRMS
                )
            }
            .frame(height: 180)

            HStack(alignment: .center) {
                statusIndicator
                Spacer()
                controlButtons
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
            monitor.refreshInputDevices()
            monitor.requestPermissionAndStart()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BlackHole Monitor")
                .font(.title2.weight(.semibold))
            Text(String(
                format: "Trigger %.2f%% · scale %.2f%% · saved per input",
                monitor.triggerThresholdRMS * 100,
                monitor.graphMaxRMS * 100
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Input", selection: Binding(
                    get: { monitor.selectedInputUID },
                    set: { monitor.selectInput(uid: $0) }
                )) {
                    ForEach(monitor.availableInputs) { input in
                        Text(input.name).tag(input.uid)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Refresh") {
                    monitor.refreshInputDevices()
                }
            }

            Toggle("Pass-through to speakers", isOn: $monitor.passThroughEnabled)
                .toggleStyle(.switch)

            Toggle("Local beep instead of Screen Sharing", isOn: Binding(
                get: { monitor.triggerResponseMode == .localBeep },
                set: { monitor.triggerResponseMode = $0 ? .localBeep : .screenSharing }
            ))
            .toggleStyle(.switch)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            if !monitor.permissionGranted {
                Button("Open Settings") {
                    monitor.openSystemSettings()
                }
            }
            Button("Start") {
                monitor.requestPermissionAndStart()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(monitor.isRunning)
            .opacity(monitor.isRunning ? 0.35 : 1)
            .keyboardShortcut(.defaultAction)

            Button("Stop") {
                monitor.stopMonitoring()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!monitor.isRunning)
            .opacity(monitor.isRunning ? 1 : 0.35)
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
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
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
        let threshold = monitor.triggerThresholdRMS
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
        .frame(width: 560, height: 400)
}
