import SwiftUI

struct ReaderDisplaySettings: View {
    @Environment(ReaderExperienceSettings.self) private var settings

    var body: some View {
        Section("reader.display.title") {
            Picker("reader.display.background", selection: binding(\.canvas)) {
                ForEach(ReaderCanvas.allCases, id: \.rawValue) { canvas in
                    Text(LocalizedStringKey("reader.canvas.\(canvas.rawValue)")).tag(canvas)
                }
            }
            .accessibilityIdentifier("reader.display.background")
            VStack(alignment: .leading) {
                Text("reader.display.brightness")
                Slider(value: binding(\.brightness), in: 0.2...1)
                    .accessibilityLabel(Text("reader.display.brightness"))
                    .accessibilityValue(settings.preferences.brightness.formatted(.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("reader.display.brightness")
                Text("reader.display.brightness.hint").font(.footnote)
            }
            Toggle("reader.display.trim", isOn: binding(\.trimsWhitespace))
                .accessibilityIdentifier("reader.display.trim")
            Picker("reader.display.rotation", selection: binding(\.quarterTurns)) {
                ForEach(0..<4, id: \.self) { turns in
                    Text(verbatim: "\(turns * 90)°").tag(turns)
                }
            }
            .accessibilityIdentifier("reader.display.rotation")
            Toggle("reader.display.keepAwake", isOn: binding(\.keepsScreenAwake))
                .accessibilityIdentifier("reader.display.keepAwake")
            Toggle("reader.display.animations", isOn: binding(\.animationsEnabled))
                .accessibilityIdentifier("reader.display.animations")
            Text("reader.display.nonDestructive").font(.footnote)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReaderDisplayPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { settings.preferences[keyPath: keyPath] },
            set: { value in settings.update { $0[keyPath: keyPath] = value } }
        )
    }
}

struct ReaderDisplaySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { ReaderDisplaySettings() }
                .navigationTitle("reader.display.title")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.ok") { dismiss() }
                            .accessibilityIdentifier("reader.display.done")
                    }
                }
        }
    }
}
