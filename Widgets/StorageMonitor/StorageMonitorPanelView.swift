import DockDoorWidgetSDK
import SwiftUI

struct StorageMonitorPanelView: View {
    let widgetId: String
    let dismiss: () -> Void

    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .frame(width: 260)
        .onAppear { refresh() }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(volume.freeLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(volume.color.opacity(0.15))

                    Capsule()
                        .fill(volume.color)
                        .frame(width: geo.size.width * volume.usedFraction)
                }
            }
            .frame(height: 4)

            Text("\(volume.usedLabel) of \(volume.totalLabel)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func refresh() {
        let fm = FileManager.default
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeLocalizedNameKey],
            options: [.skipHiddenVolumes]
        ) else { return }

        volumes = urls.compactMap { url -> VolumeInfo? in
            let name: String
            if let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]),
               let localized = values.volumeLocalizedName
            {
                name = localized
            } else {
                name = url.lastPathComponent
            }

            // attributesOfFileSystem uses statfs which works across all filesystem types
            guard let attrs = try? fm.attributesOfFileSystem(forPath: url.path),
                  let total = attrs[.systemSize] as? Int64, total > 0
            else { return nil }

            let free = attrs[.systemFreeSize] as? Int64 ?? 0

            return VolumeInfo(
                name: name,
                totalBytes: total,
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
