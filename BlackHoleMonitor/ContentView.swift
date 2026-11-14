import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: AudioLevelMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputControls
            if monitor.activityMode != .battle {
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
                        maxRMS: monitor.graphMaxRMS,
                        onEditingEnded: {
                            monitor.commitThresholdScale()
                        }
                    )
                }
                .frame(height: 180)
            } else {
                BattleVisionPreviewRow(
                    captureSource: monitor.autobattleCaptureSource,
                    tick: monitor.autobattlePreviewTick,
                    templateScore: monitor.autobattleTMRangeLabel
                )
                .frame(height: 200)
            }

            HStack(alignment: .center) {
                statusIndicator
                Spacer()
                controlButtons
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.08, green: 0.09, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        // Do NOT force .foregroundStyle(.white) on the whole tree — on Monterey
        // system buttons/fields stay light, so white labels become invisible.
        .preferredColorScheme(.dark)
        .onAppear {
            monitor.refreshInputDevices()
            monitor.requestPermissionAndStart()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bhm_12")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.white)
            Text(String(
                format: "Trigger %.2f%% · scale %.2f%% · saved per input",
                monitor.triggerThresholdRMS * 100,
                monitor.graphMaxRMS * 100
            ))
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.65))
        }
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Input")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(width: 56, alignment: .leading)
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
                .buttonStyle(.bordered)
            }

            Toggle("Pass-through to speakers", isOn: $monitor.passThroughEnabled)
                .toggleStyle(.switch)
                .foregroundStyle(Color.white.opacity(0.9))

            Picker("Activity", selection: Binding(
                get: { monitor.activityMode },
                set: { monitor.setActivityMode($0) }
            )) {
                ForEach(ActivityMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Key output", selection: $monitor.triggerResponseMode) {
                ForEach(TriggerResponseMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()

            if monitor.triggerResponseMode == .serial {
                HStack {
                    Text("Serial")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .frame(width: 56, alignment: .leading)
                    TextField(SerialPort.defaultPath, text: $monitor.serialPortPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Button(monitor.serialConnected ? "Reconnect" : "Connect") {
                        _ = monitor.reconnectSerial()
                    }
                    .buttonStyle(.bordered)
                    Circle()
                        .fill(monitor.serialConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                }
            }

            if monitor.activityMode == .battle {
                Picker("Video source", selection: $monitor.autobattleCaptureSource) {
                    ForEach(AutobattleCaptureSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Elgato camera (default) or Screen Sharing window")

                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    if monitor.autobattlePaused {
                        Button("Continue") {
                            monitor.continueAutobattle()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut(.defaultAction)
                        .help("Resume Autobattle watching after focus returned")
                    } else if monitor.isRunning {
                        Button("Pause") {
                            monitor.pauseAutobattle()
                        }
                        .buttonStyle(.bordered)
                        .help("Pause Autobattle without stopping audio")
                    }

                    Button("Unlock ROI") {
                        monitor.resetAutobattleLock()
                    }
                    .buttonStyle(.bordered)
                    .help("Clear locked button crop and search the wide strip again")

                    Button("Debug snap") {
                        monitor.captureAutobattleDebugSnapshot()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("d", modifiers: [.command])
                    .help("Overwrite debug-*.png in Documents/BlackHoleMonitor-Debug (⌘D)")

                    Button("Send A") {
                        Task { await monitor.testSendA() }
                    }
                    .buttonStyle(.bordered)
                    .help("Force-send A via current Key output (serial or Screen Sharing)")
                }

                if let debugMessage = monitor.lastDebugCaptureMessage {
                    Text(debugMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("TM soft")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .frame(width: 70, alignment: .leading)
                        Slider(
                            value: $monitor.autobattleSoftTM,
                            in: 0.40...max(0.41, monitor.autobattleHardTM)
                        )
                        Text(String(format: "%.2f", monitor.autobattleSoftTM))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("TM hard")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .frame(width: 70, alignment: .leading)
                        Slider(
                            value: $monitor.autobattleHardTM,
                            in: 0.50...0.95
                        )
                        Text(String(format: "%.2f", monitor.autobattleHardTM))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 36, alignment: .trailing)
                        Button("Reset") {
                            monitor.resetAutobattleTMThresholds()
                        }
                        .buttonStyle(.bordered)
                        .help("Reset soft=0.85 hard=0.90")
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            if !monitor.permissionGranted {
                Button("Open Settings") {
                    monitor.openSystemSettings()
                }
                .buttonStyle(.bordered)
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

    private var statusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.isRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(monitor.statusMessage)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Battle mode: show TM template + last triple-beep hit + last A-send hit instead of audio graph.
struct BattleVisionPreviewRow: View {
    let captureSource: AutobattleCaptureSource
    let tick: Int
    let templateScore: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            previewCard(
                title: "Template",
                score: templateScore,
                image: AutobattleDetector.activeTemplateNSImage()
            )
            previewCard(
                title: "Last A",
                score: AutobattleDetector.lastTriggerScoreLabel() ?? "—",
                image: loadImage(AutobattleDetector.lastTriggerROIPreviewURL())
            )
            previewCard(
                title: "Last triple beep",
                score: AutobattleDetector.lastTripleBeepScoreLabel() ?? "—",
                image: loadImage(AutobattleDetector.lastTripleBeepROIPreviewURL())
            )
        }
        // `tick` / source force image reload; templateScore updates the label only.
        .id("battle-preview-\(captureSource.rawValue)-\(tick)")
    }

    private func loadImage(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func previewCard(title: String, score: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text(score)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                if let image {
                    // GeometryReader + explicit frame so the full template fits (Monterey
                    // otherwise often clips tall/wide NSImage previews to the top half).
                    GeometryReader { geo in
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                    }
                    .padding(6)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(monitor: AudioLevelMonitor())
            .frame(width: 560, height: 400)
    }
}
