import DailyMacCore
import SwiftUI

/// A live, deliberately bounded editor: the original instrument arrangement
/// remains one click away, while every bar keeps an honest definition.
struct MenuBarIconSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var configuration = MenuBarIconConfiguration.load()

    var body: some View {
        Section("Menu bar icon") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.isStandard ? "Your original layout" : "Custom layout")
                        .font(.subheadline.weight(.semibold))
                    Text("A quick physical readout. The popover keeps the history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                iconPreview
            }
            .padding(.vertical, 5)

            Picker("Design", selection: styleBinding) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Text("Original keeps the three soft outlines you use now. Open removes only the outlines; readings and colors stay the same.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(configuration.order) { instrument in
                instrumentRow(instrument)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first.flatMap(MenuBarInstrument.init(rawValue:)) else { return false }
                        move(dragged, before: instrument)
                        return true
                    }
            }

            HStack {
                Text("Drag a handle or use the arrows to change the order. Hide any group you don't need.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore yours") { update(.standard) }
                    .disabled(configuration.isStandard)
            }
        }
        .onAppear { configuration = .load() }
    }

    private var iconPreview: some View {
        let signal = MachineStatusSignal.current(
            sample: model.latestSystem,
            recentSamples: model.recentSystemSamples
        )
        let state: MachineStatusIcon.State = signal.map { .live($0) } ?? .waiting
        let average = MachineDemandAverage.current(
            sample: model.latestSystem,
            recentSamples: model.recentSystemSamples
        )
        let freshFans = model.fanReadingsAt.map { Date().timeIntervalSince($0) < 45 } == true
            ? model.fanReadings : nil
        let icon = MachineStatusIcon.image(
            for: state,
            average: average,
            fanPercent: freshFans?.map(\.percentOfMaximum).max(),
            thermalLevel: signal == nil ? nil : model.latestSystem?.thermalLevel,
            configuration: configuration
        )
        return Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: icon.size.width * 1.8, height: 36)
            .frame(minWidth: 52, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
            }
            .accessibilityLabel("Live menu bar icon preview")
    }

    private func instrumentRow(_ instrument: MenuBarInstrument) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .draggable(instrument.rawValue)
                .help("Drag to reorder \(instrument.title)")

            Image(systemName: instrument.symbol)
                .foregroundStyle(instrument == .compute ? MachinePalette.processor : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(instrument.title)
                    .font(.subheadline.weight(.medium))
                Text(instrument.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)

            HStack(spacing: 0) {
                orderButton(instrument, direction: -1, symbol: "chevron.up", label: "Move \(instrument.title) earlier in the icon")
                orderButton(instrument, direction: 1, symbol: "chevron.down", label: "Move \(instrument.title) later in the icon")
            }
            Toggle(instrument.title, isOn: visibilityBinding(for: instrument))
                .labelsHidden()
                .help("Show \(instrument.title) in the menu bar")
        }
        .padding(.vertical, 5)
        .opacity(configuration.visible.contains(instrument) ? 1 : 0.55)
    }

    private func orderButton(_ instrument: MenuBarInstrument, direction: Int, symbol: String, label: String) -> some View {
        Button {
            guard let index = configuration.order.firstIndex(of: instrument) else { return }
            var next = configuration
            next.order.swapAt(index, index + direction)
            update(next)
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(configuration.order.firstIndex(of: instrument).map { !(configuration.order.indices.contains($0 + direction)) } ?? true)
        .help(label)
        .accessibilityLabel(label)
    }

    private var styleBinding: Binding<MenuBarIconStyle> {
        Binding(
            get: { configuration.style },
            set: { style in
                var next = configuration
                next.style = style
                update(next)
            }
        )
    }

    private func visibilityBinding(for instrument: MenuBarInstrument) -> Binding<Bool> {
        Binding(
            get: { configuration.visible.contains(instrument) },
            set: { visible in
                var next = configuration
                if visible { next.visible.insert(instrument) }
                else { next.visible.remove(instrument) }
                // Keep at least one signal in the status item.
                guard !next.visible.isEmpty else { return }
                update(next)
            }
        )
    }

    private func move(_ source: MenuBarInstrument, before target: MenuBarInstrument) {
        guard source != target else { return }
        var next = configuration
        guard let destination = next.order.firstIndex(of: target) else { return }
        next.order.removeAll { $0 == source }
        next.order.insert(source, at: destination)
        update(next)
    }

    private func update(_ value: MenuBarIconConfiguration) {
        configuration = value
        value.save()
    }
}
