import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("settings.about.section") {
                LabeledContent("settings.about.version", value: "0.1.0")
            }

            Section("settings.privacy.section") {
                Text("settings.privacy.description")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.title")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
