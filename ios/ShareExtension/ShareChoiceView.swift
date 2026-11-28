import SwiftUI
import UIKit

/// The share sheet: open the link in Z-Browser as a new tab, or send it to
/// another device on the Firefox account.
struct ShareChoiceView: View {
    let itemProviders: [NSItemProvider]
    let pageTitle: String
    /// Hands the link to the app; false when iOS would not let it.
    let openInApp: (URL) -> Bool
    let finish: () -> Void
    let cancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    init(
        itemProviders: [NSItemProvider],
        pageTitle: String,
        openInApp: @escaping (URL) -> Bool,
        finish: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.itemProviders = itemProviders
        self.pageTitle = pageTitle
        self.openInApp = openInApp
        self.finish = finish
        self.cancel = cancel
    }

    private enum Phase: Equatable {
        case loading
        case noLink
        case choose
        case devices
        case done(String)
    }

    private enum DeviceList {
        case loading
        case loaded([SendTabDevice])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var url: URL?
    @State private var title = ""
    @State private var deviceList: DeviceList = .loading
    @State private var sendingTo: String?
    @State private var sendError: String?

    private var ink: Color { Palette.ink(scheme) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .tint(Palette.coral(scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noLink:
                status(title: "No link to share", detail: "Z-Browser takes web links.", systemImage: nil)
            case .choose:
                choices
            case .devices:
                devices
            case .done(let message):
                status(title: message, detail: nil, systemImage: "checkmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: phase)
        .background(ZenSpaceGradientBackground(theme: nil, scheme: scheme).ignoresSafeArea())
        .task {
            guard let found = await ShareItemLoader.firstHTTPURL(from: itemProviders) else {
                phase = .noLink
                return
            }
            url = found
            title = pageTitle
            phase = .choose
            if title.isEmpty, let fetched = await PageTitleLoader.fetchTitle(for: found) {
                title = fetched
            }
        }
    }

    // MARK: - Choices

    private var choices: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            header
            Spacer()
            VStack(spacing: 12) {
                primaryButton("Open in Z-Browser", systemImage: "safari") { open() }
                secondaryButton("Send to device", systemImage: "laptopcomputer.and.arrow.down") {
                    phase = .devices
                    Task { await loadDevices() }
                }
                cancelButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Favicon(urlString: url?.absoluteString ?? "", size: 64)
                .padding(.bottom, 12)
            Text(title.isEmpty ? (url?.host ?? "") : title)
                .zenFont(21, weight: .semibold, design: .rounded)
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 28)
            if let text = url?.absoluteString {
                Text(text)
                    .zenFont(14, weight: .regular, design: .rounded)
                    .foregroundStyle(ink.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func open() {
        guard let url else { return }
        var components = URLComponents()
        components.scheme = "zsync"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let link = components.url, openInApp(link) {
            finish()
            return
        }
        // iOS would not open the app from here: the link waits for it.
        PendingOpens.add(url)
        phase = .done("Opens next time you open Z-Browser")
        finishSoon()
    }

    // MARK: - Devices

    private var devices: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    phase = .choose
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Back"))
                Spacer()
                Text("Send to device")
                    .zenFont(17, weight: .semibold, design: .rounded)
                    .foregroundStyle(ink)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Group {
                switch deviceList {
                case .loading:
                    ProgressView().tint(Palette.coral(scheme))
                        .frame(maxHeight: .infinity)
                case .failed(let text):
                    message(text, retry: true)
                case .loaded(let list) where list.isEmpty:
                    message("No other devices on your Firefox account can receive tabs. Sign in to Firefox or Zen on them first.", retry: true)
                case .loaded(let list):
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(list) { device in
                                deviceRow(device)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let sendError {
                Text(sendError)
                    .zenFont(14, weight: .regular, design: .rounded)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            cancelButton
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
    }

    private func deviceRow(_ device: SendTabDevice) -> some View {
        Button {
            Task { await send(to: device) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30)
                Text(device.name)
                    .zenFont(17, weight: .medium, design: .rounded)
                    .lineLimit(1)
                Spacer()
                if sendingTo == device.id {
                    ProgressView().tint(ink)
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .modifier(DomedFill(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), scheme: scheme))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LiquidPressButtonStyle())
        .disabled(sendingTo != nil)
    }

    private func message(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .zenFont(15, weight: .regular, design: .rounded)
                .foregroundStyle(ink.opacity(0.7))
                .multilineTextAlignment(.center)
            if retry {
                Button("Try again") { Task { await loadDevices() } }
                    .foregroundStyle(ink)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxHeight: .infinity)
    }

    private func loadDevices() async {
        deviceList = .loading
        do {
            deviceList = .loaded(try await SendTabService.shared.devices())
        } catch {
            deviceList = .failed(error.localizedDescription)
        }
    }

    private func send(to device: SendTabDevice) async {
        guard let url else { return }
        sendError = nil
        sendingTo = device.id
        do {
            try await SendTabService.shared.send(url: url, title: title, to: device)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .done("Sent to \(device.name)")
            finishSoon()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            sendError = error.localizedDescription
        }
        sendingTo = nil
    }

    // MARK: - Pieces

    private func finishSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            finish()
        }
    }

    private func primaryButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .zenFont(17, weight: .semibold, design: .rounded)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(Palette.paper(scheme))
                .modifier(DomedFill(shape: Capsule(), scheme: scheme, fill: ink))
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidPressButtonStyle())
    }

    private func secondaryButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .zenFont(17, weight: .semibold, design: .rounded)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(ink)
                .modifier(DomedFill(shape: Capsule(), scheme: scheme))
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidPressButtonStyle())
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Text("common.cancel")
                .zenFont(16, weight: .medium, design: .rounded)
                .foregroundStyle(ink.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedButtonStyle())
    }

    private func status(title: String, detail: String?, systemImage: String?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(ink)
                    .accessibilityHidden(true)
            }
            Text(title)
                .zenFont(21, weight: .semibold, design: .rounded)
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let detail {
                Text(detail)
                    .zenFont(15, weight: .regular, design: .rounded)
                    .foregroundStyle(ink.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
            if case .noLink = phase {
                cancelButton.padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
    }
}
