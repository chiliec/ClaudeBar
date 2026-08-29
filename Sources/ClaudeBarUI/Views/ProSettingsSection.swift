import SwiftUI
import Foundation

/// The "ClaudeBar Pro" section in Settings: shows the entitlement state and lets
/// the user upgrade (opens the Lemon Squeezy checkout), paste a license key to
/// activate, or deactivate this Mac.
///
/// Free build stays fully functional — this section only manages the Pro unlock.
public struct ProSettingsSection: View {
    @Bindable var license: LicenseStore
    @State private var keyDraft: String = ""
    @Environment(\.openURL) private var openURL

    public init(license: LicenseStore) {
        self.license = license
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusRow

                if license.isPro {
                    if license.isInGrace {
                        Text("settings.pro.grace", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await license.deactivate() }
                    } label: {
                        Text("settings.pro.deactivate", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(license.isWorking)
                } else {
                    upgradeControls
                }

                if let message = license.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(license.isPro ? .secondary : .red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("settings.pro", bundle: .module)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Circle()
                .fill(license.isPro ? .green : .secondary)
                .frame(width: 8, height: 8)
            (license.isPro
                ? Text("settings.pro.active", bundle: .module)
                : Text("settings.pro.free", bundle: .module))
                .font(.subheadline)
            Spacer()
            if license.isWorking {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var upgradeControls: some View {
        // Buy button — opens the Lemon Squeezy checkout in the browser.
        HStack {
            Button {
                if let url = ProConfig.checkoutURL { openURL(url) }
            } label: {
                Text("settings.pro.upgrade \(ProConfig.priceDisplay)", bundle: .module)
            }
            .modifier(BorderedButtonModifier())
            .controlSize(.small)
            Spacer()
        }

        Text("settings.pro.enterKey", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            TextField("", text: $keyDraft, prompt: Text("settings.pro.keyPlaceholder", bundle: .module))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
            Button {
                let key = keyDraft
                Task {
                    await license.activate(key: key, instanceName: Host.current().localizedName ?? "Mac")
                    if license.isPro { keyDraft = "" }
                }
            } label: {
                Text("settings.pro.activate", bundle: .module)
            }
            .modifier(BorderedButtonModifier())
            .controlSize(.small)
            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || license.isWorking)
        }
    }
}
