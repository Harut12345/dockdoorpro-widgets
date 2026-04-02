import SwiftUI

/// Dock orientations a widget declares support for.
///
/// Declaring an orientation means you handle **both** compact (single-slot)
/// and extended (double-slot) layouts for that orientation.
public enum WidgetOrientation: String, CaseIterable, Sendable {
    /// Bottom/top dock — wide extended slots, horizontal stacking.
    case horizontal
    /// Left/right dock — tall extended slots, vertical stacking.
    case vertical
}

/// The contract every marketplace widget must fulfill.
///
/// The host app (DockDoor Pro) calls `makeBody(size:isVertical:)` to render
/// your widget inside a widget stack slot. The `size` parameter is the content
/// area computed by the host. **Do not apply your own `.frame()`**.
///
/// ## Size contract
///
/// - `size` is the available content area, already computed from the slot
///   configuration (single or double) and dock icon size.
/// - `isVertical` is `true` when the dock is in a left or right position.
/// - Your widget must declare at least one supported orientation via
///   `supportedOrientations`. For each declared orientation you must
///   handle both compact (single-slot) and extended (double-slot) layouts.
///
/// ## Layout conventions
///
/// - `dim = min(size.width, size.height)` - use the shortest side for
///   proportional sizing.
/// - Detect double-slot with `isExtended`:
///   - Vertical dock: `size.height > size.width * 1.5`
///   - Horizontal dock: `size.width > size.height * 1.5`
/// - **Compact** (single slot): icon centered, optional small label below.
/// - **Extended vertical** (left/right dock, double slot): `VStack`,
///   icon on top, labels below.
/// - **Extended horizontal** (top/bottom dock, double slot): `HStack`,
///   icon on the left, labels on the right.
///
/// Use `WidgetMetrics` constants for consistent sizing.
public protocol DockDoorWidgetProvider: AnyObject {
    /// Unique identifier, e.g. `"storage-monitor"`.
    var id: String { get }

    /// Display name shown in settings and the widget picker.
    var name: String { get }

    /// SF Symbol name used in the settings UI.
    var iconSymbol: String { get }

    /// Short description shown in the marketplace.
    var widgetDescription: String { get }

    /// Orientations this widget supports. Must contain at least one value.
    /// For each declared orientation you must handle both compact and extended layouts.
    /// Widgets missing this field in `widget.json` will not appear in the marketplace.
    var supportedOrientations: [WidgetOrientation] { get }

    /// Return your widget's SwiftUI content wrapped in `AnyView`.
    ///
    /// - Parameters:
    ///   - size: The content area. Do NOT apply `.frame()`. The host does that.
    ///   - isVertical: `true` when the dock is positioned on the left or right.
    @MainActor func makeBody(size: CGSize, isVertical: Bool) -> AnyView

    /// Declarative settings rendered by the host app using its native UI.
    /// Return an empty array if your widget needs no settings.
    func settingsSchema() -> [WidgetSetting]

    /// Called when the user taps the widget. Override for custom tap behavior.
    func performTapAction()

    /// Optional panel content shown on long-press, right-click, or hover-activate.
    ///
    /// Return `nil` (the default) if your widget has no panel. When you return
    /// a view, the host presents it in the standard panel chrome — you only
    /// provide the content. Call `dismiss` to close the panel programmatically.
    @MainActor func makePanelBody(dismiss: @escaping () -> Void) -> AnyView?
}

public extension DockDoorWidgetProvider {
    var widgetDescription: String { "" }
    var supportedOrientations: [WidgetOrientation] { [.horizontal, .vertical] }
    func settingsSchema() -> [WidgetSetting] { [] }
    func performTapAction() {}
    @MainActor func makePanelBody(dismiss: @escaping () -> Void) -> AnyView? { nil }
}
