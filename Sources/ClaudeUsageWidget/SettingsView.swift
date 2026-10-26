import SwiftUI
import UsageCore

/// The settings behind the ellipsis button. A popover instead of a menu so it can hold a slider.
struct SettingsPanel: View {
    @EnvironmentObject var store: UsageStore

    private var delayText: String { store.hoverDelay < 0.025 ? "Instant" : String(format: "%.2f s", store.hoverDelay) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hover speed")
                    Spacer()
                    Text(delayText).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $store.hoverDelay, in: 0...1, step: 0.05) {
                    Text("Hover speed")
                } minimumValueLabel: {
                    Text("Instant").font(.caption2)
                } maximumValueLabel: {
                    Text("1 s").font(.caption2)
                }
                .labelsHidden()
                Text("How long the pointer rests on a chart before its detail card opens. Prompt, compaction and model bars open in about a seventh of that.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("Show on all desktops", isOn: $store.allDesktops)
            VStack(alignment: .leading, spacing: 3) {
                Picker("Cache write pricing", selection: $store.billing) {
                    ForEach(CacheWriteBilling.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Divider()
            HStack {
                Button("Refresh now") { store.refresh() }
                Spacer()
                if !store.archivedSessions.isEmpty {
                    Button("Restore \(store.archivedSessions.count) archived") { store.restoreAllArchived() }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
