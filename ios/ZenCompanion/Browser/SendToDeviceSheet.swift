import SwiftUI

/// A page on its way to another device on the Firefox account.
struct SendTabTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// The account's devices that receive tabs; a tap sends the page there.
struct SendToDeviceSheet: View {
    let target: SendTabTarget

    @Environment(\.dismiss) private var dismiss

    private enum Load {
        case loading
        case loaded([SendTabDevice])
        case failed(String)
    }

    @State private var load: Load = .loading
    @State private var sendingTo: String?
    @State private var sentTo: String?
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch load {
                case .loading:
                    ProgressView()
                case .failed(let text):
                    unavailable(text)
                case .loaded(let devices) where devices.isEmpty:
                    unavailable("No other devices on your Firefox account can receive tabs. Sign in to Firefox or Zen on them first.")
                case .loaded(let devices):
                    List {
                        Section {
                            ForEach(devices) { device in
                                row(device)
                            }
                        } footer: {
                            if let sendError {
                                Text(sendError).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Send to device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await loadDevices() }
    }

    private func row(_ device: SendTabDevice) -> some View {
        Button {
            Task { await send(to: device) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: device.symbolName)
                    .frame(width: 28)
                Text(device.name)
                    .lineLimit(1)
                Spacer()
                if sendingTo == device.id {
                    ProgressView()
                } else if sentTo == device.id {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .foregroundStyle(Color.primary)
        }
        .disabled(sendingTo != nil || sentTo != nil)
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again") { Task { await loadDevices() } }
        }
        .padding(32)
    }

    private func loadDevices() async {
        load = .loading
        do {
            load = .loaded(try await SendTabService.shared.devices())
        } catch {
            load = .failed(error.localizedDescription)
        }
    }

    private func send(to device: SendTabDevice) async {
        sendError = nil
        sendingTo = device.id
        do {
            try await SendTabService.shared.send(url: target.url, title: target.title, to: device)
            sendingTo = nil
            sentTo = device.id
            AppServices.haptics.pinSucceeded()
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        } catch {
            sendingTo = nil
            sendError = error.localizedDescription
        }
    }
}
