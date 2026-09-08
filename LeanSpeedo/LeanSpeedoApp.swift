import SwiftUI
import AppKit
import Combine
import ServiceManagement

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
    private var pendingReset: Task<Void, Never>?
    private var logWindow: NSWindow?
    private var isPulsing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = SpeedPanel(checker: checker) { [weak self] detail in
            self?.showLog(detail)
        }
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Internet Speed")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.focusRingType = .none
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        checker.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state: state) }
            }
            .store(in: &cancellables)
    }

    // MARK: - State handling

    private func handle(state: SpeedChecker.State) {
        setRunningIndicator(state == .running)
        updateTooltip(state)

        // Re-open the panel when a test finishes while it's closed.
        guard !popover.isShown else { return }
        switch state {
        case .result, .failure: showPopover()
        case .idle, .running: break
        }
    }

    private func updateTooltip(_ state: SpeedChecker.State) {
        switch state {
        case .idle:
            statusItem.button?.toolTip = "LeanSpeedo"
        case .running:
            statusItem.button?.toolTip = "Testing…"
        case .result(let s):
            statusItem.button?.toolTip = "↓ \(s.download)   ↑ \(s.upload)   \(s.responsiveness)"
        case .failure(let f):
            statusItem.button?.toolTip = f.message
        }
    }

    // MARK: - Running indicator

    private func setRunningIndicator(_ running: Bool) {
        guard running != isPulsing else { return }
        isPulsing = running
        guard let button = statusItem.button else { return }

        if running {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button.alphaValue = 0.5          // static dim, no pulse
            } else {
                pulseStep(dimming: true)
            }
        } else {
            button.animator().alphaValue = 1.0
        }
    }

    private func pulseStep(dimming: Bool) {
        guard isPulsing, let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = dimming ? 0.35 : 1.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.pulseStep(dimming: !dimming) }
        }
    }

    // MARK: - Clicks & menu

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRight {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let test = NSMenuItem(title: checker.isRunning ? "Testing…" : "Run Speed Test",
                              action: #selector(menuRunTest), keyEquivalent: "")
        test.target = self
        test.isEnabled = !checker.isRunning
        menu.addItem(test)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LeanSpeedo",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func menuRunTest() {
        checker.run()
        if !popover.isShown { showPopover() }
    }

    @objc private func menuToggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }

    private var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("LeanSpeedo: launch-at-login toggle failed: \(error)")
            }
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        pendingReset?.cancel()
        pendingReset = nil
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Make the panel's window key so its controls render active (not grayed)
        // even when it re-opens itself after a test. Nothing inside is focusable
        // (see SpeedPanel), so this doesn't route the keyboard to any button.
        if let window = popover.contentViewController?.view.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
        }

        // Kick off a test as soon as the panel opens fresh.
        if case .idle = checker.state {
            checker.run()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Keep results around briefly so a quick re-open still shows them.
        pendingReset?.cancel()
        pendingReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.checker.reset()
        }
    }

    // MARK: - Error log window

    private func showLog(_ text: String) {
        popover.performClose(nil)

        let controller = NSHostingController(rootView: LogView(text: text))
        let window = logWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Speed Test Log"
            w.isReleasedWhenClosed = false
            w.center()
            logWindow = w
            return w
        }()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Panel

private struct SpeedPanel: View {
    @ObservedObject var checker: SpeedChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onShowDetail: (String) -> Void

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

            case .failure(let failure):
                VStack(alignment: .leading, spacing: 6) {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show details") { onShowDetail(failure.detail) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .focusable(false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionButton(title: "Retest")
            }
        }
        .padding(14)
        .frame(width: 240)
        .focusEffectDisabled()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: checker.state)
    }

    // MARK: Metric rows

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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: data.fraction)
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

        case .result(let summary):
            return (RowData(value: summary.download, fraction: 1),
                    RowData(value: summary.upload, fraction: 1),
                    RowData(value: summary.responsiveness, fraction: 1))
        }
    }

    private static func mbps(_ value: Double) -> String {
        value <= 0 ? "…" : String(format: "%.1f Mbps", value)
    }

    private static func rpm(_ value: Double) -> String {
        value <= 0 ? "…" : "\(Int(value.rounded())) RPM"
    }

    private func actionButton(title: String) -> some View {
        Button(title) {
            checker.run()
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .focusable(false)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Log window content

private struct LogView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text.isEmpty ? "No output." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

// MARK: - Measurement

@MainActor
final class SpeedChecker: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case running
        case result(Summary)
        case failure(Failure)
    }

    struct Summary: Sendable, Equatable {
        let download: String
        let upload: String
        let responsiveness: String
    }

    struct Failure: Error, Sendable, Equatable {
        let message: String   // short, human-readable
        let detail: String    // full output / underlying error
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

    /// Hard limit on a single run, in seconds. `networkQuality` normally
    /// finishes in ~15–25s.
    nonisolated private static let timeoutSeconds: TimeInterval = 60

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
                let summary = try await Self.measure { download, upload, responsiveness in
                    Task { @MainActor [weak self] in
                        self?.live.update(download: download,
                                          upload: upload,
                                          responsiveness: responsiveness)
                    }
                }
                state = .result(summary)
            } catch let failure as Failure {
                state = .failure(failure)
            } catch {
                state = .failure(Failure(message: "The speed test failed.",
                                         detail: String(describing: error)))
            }
        }
    }

    /// Clears results when the popover closes. A test in progress is left alone.
    func reset() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: Streaming measurement

    nonisolated private static func measure(
        onProgress: @escaping @Sendable (_ download: Double, _ upload: Double, _ responsiveness: Double) -> Void
    ) async throws -> Summary {
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
                    continuation.resume(throwing: Failure(
                        message: "Could not start the speed test.",
                        detail: String(describing: error)))
                    return
                }

                // Kill the run if networkQuality wedges (captive portal, dead link).
                let timeout = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeout)

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
                timeout.cancel()

                let output = String(decoding: buffer, as: UTF8.self).replacing(ansi, with: "")
                let didTimeOut = process.terminationReason == .uncaughtSignal

                guard !didTimeOut,
                      process.terminationStatus == 0,
                      let downlink = output.firstMatch(of: downlinkCapacity).flatMap({ Double($0.1) }),
                      let uplink = output.firstMatch(of: uplinkCapacity).flatMap({ Double($0.1) }) else {
                    continuation.resume(throwing: Self.classify(output: output, timedOut: didTimeOut))
                    return
                }

                let rpm = output.firstMatch(of: responsivenessLine).flatMap { Double($0.1) } ?? lastResponsiveness

                continuation.resume(returning: Summary(
                    download: String(format: "%.1f Mbps", downlink),
                    upload: String(format: "%.1f Mbps", uplink),
                    responsiveness: rpm > 0 ? "\(Int(rpm.rounded())) RPM" : "—"))
            }
        }
    }

    nonisolated private static func classify(output: String, timedOut: Bool) -> Failure {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if timedOut {
            return Failure(
                message: "The speed test timed out.",
                detail: detail.isEmpty ? "networkQuality did not finish within 60 seconds." : detail)
        }

        let offlineHints = ["offline", "no network route", "network is down",
                            "not connect", "-1009", "unsatisfied", "nw_path"]
        let lowered = detail.lowercased()
        let offline = offlineHints.contains { lowered.contains($0) }

        return Failure(
            message: offline ? "No internet connection." : "The speed test failed.",
            detail: detail.isEmpty ? "networkQuality exited without any output." : detail)
    }
}
