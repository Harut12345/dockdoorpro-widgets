import SwiftUI
import DockDoorWidgetSDK

struct ClipboardWidgetView: View {
    let size: CGSize
    let isVertical: Bool
    @ObservedObject var monitor: ClipboardMonitor
    var iconSymbol: String = "clipboard.fill"
    /// Controlled by the "Show icon" setting in widget parameters.
    /// Default false: the extended view shows only text.
    var showIcon: Bool = false

    private var dim: CGFloat { min(size.width, size.height) }
    private var isExtended: Bool {
        isVertical ? size.height > size.width * 1.5 : size.width > size.height * 1.5
    }

    var body: some View {
        Group {
            if isExtended { extendedLayout } else { compactLayout }
        }
    }

    // MARK: - Compact: icon only

    private var compactLayout: some View {
        Image(systemName: iconSymbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: dim * 0.437, height: dim * 0.437)
            .foregroundStyle(.secondary)
    }

    // MARK: - Extended: centered text (+ optional icon)

    private var lastCopied: ClipboardItem? {
        monitor.items.first { !$0.isPinned }
    }

    private var extendedLayout: some View {
        HStack(spacing: dim * 0.08) {
            if showIcon {
                Image(systemName: iconSymbol)
                    .font(.system(size: dim * 0.28))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let last = lastCopied {
                ScrollingTextWidget(item: last, dim: dim, isVertical: isVertical)
            } else {
                Text(S("Vide", "Empty"))
                    .font(.system(size: dim * 0.28))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(dim * 0.10)
    }
}

// MARK: - Scrolling widget text

private struct ScrollingTextWidget: View {
    let item: ClipboardItem
    let dim: CGFloat
    let isVertical: Bool

    private var fontSize: CGFloat {
        let proportional = isVertical ? dim * 0.30 : dim * 0.32
        return max(proportional - 1, 9)
    }

    private var minScaleFactor: CGFloat {
        fontSize > 9 ? (9 / fontSize) : 1.0
    }

    var body: some View {
        Text(item.displayTitle)
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(minScaleFactor)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
