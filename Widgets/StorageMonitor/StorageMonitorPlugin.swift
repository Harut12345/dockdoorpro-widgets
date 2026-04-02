import DockDoorWidgetSDK
import SwiftUI

final class StorageMonitorPlugin: WidgetPlugin, DockDoorWidgetProvider {
    var id: String { "storage-monitor" }
    var name: String { "Storage" }
    var iconSymbol: String { "internaldrive" }
    var widgetDescription: String { "Shows available disk space" }
    var supportedOrientations: [WidgetOrientation] { [.horizontal, .vertical] }

    func settingsSchema() -> [WidgetSetting] {
        [
            .toggle(key: "showPercentage", label: "Show Percentage Instead of GB", defaultValue: false),
            .slider(key: "warningThreshold", label: "Warning Threshold (%)", range: 50...95, step: 5, defaultValue: 75),
            .picker(key: "ringStyle", label: "Ring Style", options: ["Rounded", "Flat"], defaultValue: "Rounded"),
        ]
    }

    @MainActor
    func makeBody(size: CGSize, isVertical: Bool) -> AnyView {
        AnyView(StorageMonitorView(size: size, isVertical: isVertical, widgetId: id))
    }

    @MainActor
    func makePanelBody(dismiss: @escaping () -> Void) -> AnyView? {
        AnyView(StorageMonitorPanelView(widgetId: id, dismiss: dismiss))
    }
}
