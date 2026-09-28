import Foundation

enum MenuBarInstrument: String, CaseIterable, Identifiable {
    case physical
    case compute
    case state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .physical: "Fan + heat"
        case .compute: "CPU + GPU"
        case .state: "Overall state"
        }
    }

    var explanation: String {
        switch self {
        case .physical:
            "Left bar: measured fan speed relative to its reported maximum. Right bar: macOS thermal-pressure category, not temperature or power. Gray means unavailable."
        case .compute:
            "Two-minute CPU and GPU demand. Blue fills show how much of each processor is in use; gray means no fresh reading."
        case .state:
            "Upper bar: machine health. Lower bar: current effort, in four steps. Color changes only when the measured state warrants it."
        }
    }

    var symbol: String {
        switch self {
        case .physical: "fanblades"
        case .compute: "cpu"
        case .state: "waveform.path.ecg"
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case original
    case open

    var id: String { rawValue }
    var label: String { self == .original ? "Original" : "Open" }
}

struct MenuBarIconConfiguration: Equatable {
    static let didChangeNotification = Notification.Name("MenuBarIconConfigurationDidChange")
    static let orderKey = "menuBarIconOrder"
    static let visibleKey = "menuBarIconVisible"
    static let styleKey = "menuBarIconStyle"

    static let standard = Self(
        order: MenuBarInstrument.allCases,
        visible: Set(MenuBarInstrument.allCases),
        style: .original
    )

    var order: [MenuBarInstrument]
    var visible: Set<MenuBarInstrument>
    var style: MenuBarIconStyle

    init(order: [MenuBarInstrument], visible: Set<MenuBarInstrument>, style: MenuBarIconStyle) {
        // Preferences from older or future builds must never hide an instrument
        // forever or duplicate one in the status bar.
        var unique: [MenuBarInstrument] = []
        for instrument in order + MenuBarInstrument.allCases where !unique.contains(instrument) {
            unique.append(instrument)
        }
        self.order = unique
        self.visible = visible.isEmpty ? Set(MenuBarInstrument.allCases) : visible
        self.style = style
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let order = (defaults.string(forKey: orderKey) ?? "")
            .split(separator: ",")
            .compactMap { MenuBarInstrument(rawValue: String($0)) }
        let visible = Set((defaults.string(forKey: visibleKey) ?? "physical,compute,state")
            .split(separator: ",")
            .compactMap { MenuBarInstrument(rawValue: String($0)) })
        return Self(
            order: order,
            visible: visible,
            style: MenuBarIconStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .original
        )
    }

    var displayedInstruments: [MenuBarInstrument] { order.filter { visible.contains($0) } }
    var isStandard: Bool { self == Self.standard }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.rawValue).joined(separator: ","), forKey: Self.orderKey)
        defaults.set(MenuBarInstrument.allCases.filter { visible.contains($0) }
            .map(\.rawValue).joined(separator: ","), forKey: Self.visibleKey)
        defaults.set(style.rawValue, forKey: Self.styleKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
