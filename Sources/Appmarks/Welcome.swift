import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// First-run guide to the two permissions. System Settings gives no callback when one is granted,
/// so the view polls while it is open and the window is dropped on close to stop that.
@MainActor
final class WelcomeWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() })
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window = nil }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum Permission: CaseIterable {
    case accessibility, screenRecording

    static var allGranted: Bool { allCases.allSatisfy(\.isGranted) }

    var isGranted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// Asking first adds Appmarks to the list in System Settings, so there is a switch to turn on.
    func request() {
        switch self {
        case .accessibility:
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        }
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct WelcomeView: View {
    let done: () -> Void
    @State private var accessibility = Permission.accessibility.isGranted
    @State private var screenRecording = Permission.screenRecording.isGranted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var allGranted: Bool { accessibility && screenRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "rectangle.leadinghalf.inset.filled")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text("Welcome to Appmarks")
                    .font(.title.weight(.semibold))
                Text("Appmarks parks the windows you're not using at the edge of the screen. macOS needs your OK before it can do that.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                PermissionRow(title: "Accessibility",
                              detail: "Lets Appmarks move and park your windows.",
                              granted: accessibility) { Permission.accessibility.request() }
                Divider().padding(.leading, 40)
                PermissionRow(title: "Screen Recording",
                              detail: "Shows a live picture of each parked window. Pictures stay on your Mac.",
                              granted: screenRecording) { Permission.screenRecording.request() }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(allGranted
                     ? "You're set. Appmarks is running in the menu bar."
                     : "Turn on Appmarks in each list System Settings opens. After Screen Recording, macOS asks to quit and reopen Appmarks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(allGranted ? .defaultAction : .cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 460)
        .onReceive(poll) { _ in
            accessibility = Permission.accessibility.isGranted
            screenRecording = Permission.screenRecording.isGranted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Allowed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: open)
            }
        }
        .padding(12)
    }
}
