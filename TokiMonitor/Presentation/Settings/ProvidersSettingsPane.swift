import SwiftUI

struct ProvidersSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            if let first = ProviderRegistry.configurableProviders.first {
                Section {
                    providerRow(first)
                        .background(scrollTopTracker)
                } header: {
                    Label(first.name, systemImage: first.icon)
                        .foregroundStyle(first.color)
                }
                ForEach(ProviderRegistry.configurableProviders.dropFirst()) { provider in
                    Section {
                        providerRow(provider)
                    } header: {
                        Label(provider.name, systemImage: provider.icon)
                            .foregroundStyle(provider.color)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func providerRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)

        return Toggle(L.provider.enabled, isOn: Binding(
            get: { ps.enabled },
            set: { newVal in
                settings.setProviderEnabled(
                    provider.id,
                    enabled: newVal,
                    tokiProviderId: provider.tokiProviderId
                )
            }
        ))
    }

}
