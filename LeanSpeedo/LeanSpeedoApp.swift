import SwiftUI
import AppKit
import Combine

@main
struct LeanSpeedoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let checker = SpeedChecker()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: SpeedPanel(checker: checker))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Internet Speed")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.focusRingType = .none

        checker.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.handle(state: state)
                }
            }
            .store(in: &cancellables)
    }

    private func handle(state: SpeedChecker.State) {
        setRunningIndicator(state == .running)

        // Re-open the panel when a test finishes while it's closed.
        guard !popover.isShown else { return }
        switch state {
        case .result, .failure: showPopover()
        case .idle, .running: break
        }
    }

    private var isPulsing = false

    private func setRunningIndicator(_ running: Bool) {
        guard running != isPulsing else { return }
        isPulsing = running
        if running {
            pulseStep(dimming: true)
        } else {
            statusItem.button?.alphaValue = 1.0
        }
    }

    private func pulseStep(dimming: Bool) {
        guard isPulsing, let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = dimming ? 0.35 : 1.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.pulseStep(dimming: !dimming)
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Don't let the popover take keyboard focus — otherwise Space/Return
        // would trigger whichever button is first responder (e.g. Quit).
        popover.contentViewController?.view.window?.makeFirstResponder(nil)

        // Kick off a test as soon as the panel opens fresh.
        if case .idle = checker.state {
            checker.run()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        checker.reset()
    }
}

private struct SpeedPanel: View {
    @ObservedObject var checker: SpeedChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Internet Speed")
                .font(.headline)

            metrics

            switch checker.state {
            case .idle:
                actionButton(title: "Test")

            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Testing…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            case .result:
                actionButton(title: "Retest")

            case .failure(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton(title: "Retest")
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .focusable(false)
            }
        }
        .padding(14)
        .frame(width: 240)
        .focusEffectDisabled()
    }

    // MARK: - Metric rows

    private var metrics: some View {
        let rows = rowData()
        return VStack(spacing: 10) {
            metricRow("Download", rows.download)
            metricRow("Upload", rows.upload)
            metricRow("Responsiveness", rows.responsiveness)
        }
    }

    private func metricRow(_ label: String, _ data: RowData) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(data.value ?? "—")
                    .fontWeight(.medium)
                    .foregroundStyle(data.value == nil ? Color.secondary : Color.primary)
                    .contentTransition(.numericText())
            }
            .font(.callout)

            ProgressView(value: min(max(data.fraction, 0), 1))
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: data.fraction)
        }
    }

    private struct RowData {
        var value: String?
        var fraction: Double
    }

    private func rowData() -> (download: RowData, upload: RowData, responsiveness: RowData) {
        switch checker.state {
        case .idle, .failure:
            return (RowData(value: nil, fraction: 0),
                    RowData(value: nil, fraction: 0),
                    RowData(value: nil, fraction: 0))

        case .running:
            let live = checker.live
            return (RowData(value: Self.mbps(live.download), fraction: live.downloadFraction),
                    RowData(value: Self.mbps(live.upload), fraction: live.uploadFraction),
                    RowData(value: Self.rpm(live.responsiveness), fraction: live.responsivenessFraction))

        case .result(let result):
            return (RowData(value: result.download, fraction: 1),
                    RowData(value: result.upload, fraction: 1),
                    RowData(value: result.responsiveness, fraction: 1))
        }
    }

    private static func mbps(_ value: Double) -> String {
        value <= 0 ? "…" : String(format: "%.1f Mbps", value)
    }

    private static func rpm(_ value: Double) -> String {
        value <= 0 ? "…" : "\(Int(value.rounded())) RPM"
    }

    // MARK: - Button

    private func actionButton(title: String) -> some View {
        Button(title) {
            checker.run()
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

@MainActor
final class SpeedChecker: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case running
        case result(Result)
        case failure(String)
    }

    struct Result: Sendable, Equatable {
        let download: String
        let upload: String
        let responsiveness: String
    }

    /// Live readings streamed out of `networkQuality` while a test runs.
    /// Each bar is scaled against the largest value seen so far (with a floor),
    /// so it climbs as the connection ramps up and pins near full at the top.
    struct Live: Equatable {
        var download = 0.0        // Mbps
        var upload = 0.0          // Mbps
        var responsiveness = 0.0  // RPM

        var downloadCeiling = 80.0
        var uploadCeiling = 80.0
        var responsivenessCeiling = 250.0

        var downloadFraction: Double { download / downloadCeiling }
        var uploadFraction: Double { upload / uploadCeiling }
        var responsivenessFraction: Double { responsiveness / responsivenessCeiling }

        mutating func update(download: Double, upload: Double, responsiveness: Double) {
            self.download = download
            self.upload = upload
            self.responsiveness = responsiveness
            downloadCeiling = max(downloadCeiling, download)
            uploadCeiling = max(uploadCeiling, upload)
            responsivenessCeiling = max(responsivenessCeiling, responsiveness)
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var live = Live()

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func run() {
        guard !isRunning else { return }
        live = Live()
        state = .running

        Task {
            do {
                let result = try await Self.measure { download, upload, responsiveness in
                    Task { @MainActor [weak self] in
                        self?.live.update(download: download,
                                          upload: upload,
                                          responsiveness: responsiveness)
                    }
                }
                withAnimation(.easeOut(duration: 0.4)) {
                    state = .result(result)
                }
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    /// Clears results when the popover closes. A test in progress is left alone.
    func reset() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: - Streaming measurement

    nonisolated private static func measure(
        onProgress: @escaping @Sendable (_ download: Double, _ upload: Double, _ responsiveness: Double) -> Void
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ansi = /\x1b\[[0-9;]*[A-Za-z]/
                let liveLine = /Downlink:\s*([0-9.]+)\s*Mbps,\s*([0-9]+)\s*RPM\s*-\s*Uplink:\s*([0-9.]+)\s*Mbps/
                let downlinkCapacity = /Downlink capacity:\s*([0-9.]+)\s*Mbps/
                let uplinkCapacity = /Uplink capacity:\s*([0-9.]+)\s*Mbps/
                let responsivenessLine = /Responsiveness:[^|]*\|\s*([0-9]+)\s*RPM/

                let process = Process()
                // `script` gives networkQuality a pseudo-terminal, which is the only
                // way it emits its live progress line instead of just a final summary.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
                process.arguments = ["-q", "/dev/null", "/usr/bin/networkQuality"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let handle = pipe.fileHandleForReading
                var buffer = Data()
                var lastResponsiveness = 0.0

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    buffer.append(chunk)

                    let text = String(decoding: buffer, as: UTF8.self).replacing(ansi, with: "")
                    if let match = text.matches(of: liveLine).last {
                        let download = Double(match.1) ?? 0
                        let responsiveness = Double(match.2) ?? 0
                        let upload = Double(match.3) ?? 0
                        lastResponsiveness = responsiveness
                        onProgress(download, upload, responsiveness)
                    }
                }

                process.waitUntilExit()

                let output = String(decoding: buffer, as: UTF8.self).replacing(ansi, with: "")

                guard process.terminationStatus == 0,
                      let downlink = output.firstMatch(of: downlinkCapacity).flatMap({ Double($0.1) }),
                      let uplink = output.firstMatch(of: uplinkCapacity).flatMap({ Double($0.1) }) else {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NSError(
                        domain: "LeanSpeedo",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: trimmed.isEmpty ? "networkQuality failed" : trimmed]
                    ))
                    return
                }

                let rpm = output.firstMatch(of: responsivenessLine).flatMap { Double($0.1) } ?? lastResponsiveness

                continuation.resume(returning: Result(
                    download: String(format: "%.1f Mbps", downlink),
                    upload: String(format: "%.1f Mbps", uplink),
                    responsiveness: rpm > 0 ? "\(Int(rpm.rounded())) RPM" : "—"
                ))
            }
        }
    }
}
