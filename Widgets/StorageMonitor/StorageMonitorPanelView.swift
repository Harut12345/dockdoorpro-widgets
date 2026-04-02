import DockDoorWidgetSDK
import SwiftUI

struct StorageMonitorPanelView: View {
    let widgetId: String
    let dismiss: () -> Void

    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "internaldrive")
                    .font(.title3.weight(.semibold))
                Text("Storage")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            if volumes.isEmpty {
                Text("No volumes found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(volumes) { volume in
                    volumeRow(volume)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { refresh() }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(volume.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(volume.freeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(volume.color.opacity(0.15))

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(volume.color)
                        .frame(width: geo.size.width * volume.usedFraction)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(volume.usedLabel) used")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(volume.totalLabel) total")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        }
    }

    private func refresh() {
        let fm = FileManager.default
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey],
            options: [.skipHiddenVolumes]
        ) else { return }

        volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeLocalizedNameKey,
            ]) else { return nil }

            guard let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let name = values.volumeLocalizedName ?? url.lastPathComponent

            return VolumeInfo(
                name: name,
                totalBytes: Int64(total),
                freeBytes: free
            )
        }
    }
}

struct VolumeInfo: Identifiable {
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64

    var id: String { name }

    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var usedGB: Double { totalGB - freeGB }

    var usedFraction: Double {
        guard totalGB > 0 else { return 0 }
        return min(1, max(0, usedGB / totalGB))
    }

    var color: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .blue
    }

    var freeLabel: String { formatGB(freeGB) + " free" }
    var usedLabel: String { formatGB(usedGB) }
    var totalLabel: String { formatGB(totalGB) }

    private func formatGB(_ gb: Double) -> String {
        if gb >= 100 { return "\(Int(gb)) GB" }
        return String(format: "%.1f GB", gb)
    }
}
