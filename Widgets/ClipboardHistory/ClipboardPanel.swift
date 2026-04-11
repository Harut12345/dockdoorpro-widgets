import AppKit
import SwiftUI
import PDFKit
import AVFoundation
import AVKit
import Quartz

// MARK: - Custom NSPanel (accepts keyboard input)

/// NSPanel subclass that allows keyboard focus while remaining non-activating.
/// Required so that text fields and keyboard shortcuts work
/// in the floating panel without stealing focus from the active application.
final class EditablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Accent color helper

private extension Color {
    /// System accent color darkened by ~20% for a less vivid appearance.
    /// Static cache: avoids recalculating the blend on every access.
    static let accentAttenuation: Color = {
        Color(NSColor.controlAccentColor.blended(withFraction: 0.22, of: .black) ?? .controlAccentColor)
    }()
}

// MARK: - Shared helpers

private extension DateFormatter {
    // OPTIMISATION 1: DateFormatter is expensive to instantiate — created once
    // at startup (lazy static let) instead of recreating it on every date display.
    static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = L.dateLocale; return f
    }()
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = L.dateLocale
        f.dateFormat = widgetLanguage() == "en" ? "MMM d, HH:mm" : "d MMMM HH:mm"
        return f
    }()
}

// MARK: - PNG helper for image saving

private func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bmp  = NSBitmapImageRep(data: tiff) else { return nil }
    return bmp.representation(using: .png, properties: [:])
}

// MARK: - Filter enum

enum ClipboardFilter: String, CaseIterable {
    case all   = "all"
    case media = "media"
    case data  = "data"

    /// Label translated according to the active language.
    var label: String {
        switch self {
        case .all:   return L.all
        case .media: return L.media
        case .data:  return L.data
        }
    }

    var icon: String {
        switch self {
        case .all:   return "square.grid.2x2"
        case .media: return "photo"
        case .data:  return "info.circle"
        }
    }
}

// MARK: - Color detection
// OPTIMISATION 9: the regex and detectColor function have been moved into
// ClipboardItem (ClipboardMonitor.swift) and the result is cached at item
// creation time in `cachedColor`. A local alias is kept here for the few
// calls that operate on raw text outside of a ClipboardItem.
private func detectColor(in text: String) -> Color? {
    ClipboardItem.detectColorStatic(in: text)
}

// MARK: - Color swatch

private struct ColorSwatchView: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - File preview (content-based, no QLPreviewView)

/// PDF preview with page navigation buttons ← →
private struct PDFPagesPreview: View {
    let url: URL
    @State private var currentPage: Int = 0
    @State private var pageCount:   Int = 0

    var body: some View {
        VStack(spacing: 0) {
            PDFKitView(url: url, currentPage: $currentPage, pageCount: $pageCount)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if pageCount > 1 {
                HStack(spacing: 12) {
                    Button {
                        if currentPage > 0 { currentPage -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 28)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPage == 0)

                    Text("\(currentPage + 1) / \(pageCount)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 48)

                    Button {
                        if currentPage < pageCount - 1 { currentPage += 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 28)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPage == pageCount - 1)
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var currentPage: Int
    @Binding var pageCount:   Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales         = true
        pdfView.displayMode        = .singlePage
        pdfView.displayDirection   = .horizontal
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor    = .clear
        pdfView.pageShadowsEnabled = false
        // Remove the background of the internal scroll view
        if let scrollView = pdfView.subviews.first as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.contentView.layer?.backgroundColor = .none
        }
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
            DispatchQueue.main.async {
                pageCount   = doc.pageCount
                currentPage = 0
            }
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard let doc  = pdfView.document,
              let page = doc.page(at: currentPage),
              pdfView.currentPage != page else { return }
        pdfView.go(to: page)
    }

    class Coordinator: NSObject {
        var parent: PDFKitView
        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let doc     = pdfView.document,
                  let page    = pdfView.currentPage else { return }
            DispatchQueue.main.async {
                self.parent.currentPage = doc.index(for: page)
            }
        }
    }
}

/// Text preview: reads the file in UTF-8 and displays it in a scrollable view.
/// Works for .txt, .swift, .py, .js, .html, .css, .md, .json, .xml, etc.
private struct TextFilePreview: View {
    let url: URL
    @State private var text:   String = ""
    @State private var failed: Bool   = false

    var body: some View {
        Group {
            if failed {
                UnsupportedFilePreview(url: url)
            } else if text.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: url) { load() }
    }

    private func load() {
        text   = ""
        failed = false
        DispatchQueue.global(qos: .userInitiated).async {
            // Read up to 200 KB to avoid blocking the UI with large files
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                DispatchQueue.main.async { failed = true }
                return
            }
            let data   = handle.readData(ofLength: 200_000)
            handle.closeFile()
            let result = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1)
            DispatchQueue.main.async {
                if let result { text = result } else { failed = true }
            }
        }
    }
}

/// Image preview (png, jpg, gif, webp, tiff, heic…)
private struct ImageFilePreview: View {
    let url: URL
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(8)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: url)
                DispatchQueue.main.async { image = img }
            }
        }
    }
}

/// Custom NSView with a direct AVPlayerLayer — no black background possible.
/// Unlike AVPlayerView, we control exactly what is drawn.
private final class NSLayerPlayerView: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// AVPlayer wrapped in NSViewRepresentable via a direct layer.
/// 100% transparent background: no black bars, no zoom.
private struct AVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSLayerPlayerView {
        NSLayerPlayerView(player: player)
    }

    func updateNSView(_ view: NSLayerPlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// Video preview: thumbnail (frame extracted at preview size) + play icon.
/// A tap starts the video directly in the view via AVPlayer — no external window.
private struct VideoFilePreview: View {
    let url: URL
    @State private var image:            NSImage? = nil
    @State private var player:           AVPlayer? = nil
    @State private var videoReadyToShow: Bool = false   // true as soon as the first frame is rendered
    @State private var isMuted:          Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Permanent thumbnail in background ────────────────────────
                // Visible until the video renders its first real frame
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: geo.size.width, height: geo.size.height)
                    ProgressView()
                }

                // ── Player — visible only after the first frame ───────────────
                if let currentPlayer = player {
                    AVPlayerView(player: currentPlayer)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .opacity(videoReadyToShow ? 1 : 0)
                }

                // ── Play icon (shown when not playing) ───────────────────────
                if player == nil {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 52, height: 52)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    }
                }

                // ── Mute/unmute button (visible only during playback) ─────────
                if player != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                if let currentPlayer = player {
                                    currentPlayer.isMuted.toggle()
                                    isMuted.toggle()
                                }
                            } label: {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(.black.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                        Spacer()
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onTapGesture {
                if player == nil {
                    let newPlayer = AVPlayer(url: url)
                    player = newPlayer
                    newPlayer.play()
                    // Show the player as soon as it actually starts playing
                    observeFirstPlayback(newPlayer)
                } else {
                    if player?.timeControlStatus == .playing {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                }
            }
            .onAppear { load(size: geo.size) }
            .onChange(of: url) {
                player = nil
                videoReadyToShow = false
                load(size: geo.size)
            }
        }
        .padding(8)
    }

    /// Watches timeControlStatus: as soon as the player is truly playing (first frame shown),
    /// the player is made visible. Light polling every 50 ms, stops on success.
    private func observeFirstPlayback(_ currentPlayer: AVPlayer) {
        var attempts = 0
        func check() {
            guard attempts < 40 else { return }   // 2 s timeout
            attempts += 1
            if currentPlayer.timeControlStatus == .playing {
                DispatchQueue.main.async { videoReadyToShow = true }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
    }

    /// Decodes the thumbnail at most to the actual view size — never in 4K.
    private func load(size: CGSize) {
        guard player == nil else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPx  = max(size.width, size.height, 1) * scale
        DispatchQueue.global(qos: .userInitiated).async {
            let img = VideoThumbnailURL.extractFramePublic(from: url, maxSize: maxPx)
            DispatchQueue.main.async { image = img }
        }
    }
}

// MARK: - Real QuickLook preview (QLPreviewView) for docx, pages, psd, xlsx, pptx, keynote…

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts  = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem as? URL != url {
            view.previewItem = url as QLPreviewItem
        }
    }
}

// MARK: - Archive contents (zip / tar / gz / 7z…)

private struct ArchivePreview: View {
    let url: URL
    @State private var entries:   [String] = []
    @State private var truncated: Bool     = false
    @State private var failed:    Bool     = false

    var body: some View {
        Group {
            if failed {
                UnsupportedFilePreview(url: url)
            } else if entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.52, green: 0.34, blue: 0.20))
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(url.pathExtension.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(red: 0.52, green: 0.34, blue: 0.20).opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Color(red: 0.52, green: 0.34, blue: 0.20))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)

                    Divider().opacity(0.3)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries, id: \.self) { entry in
                                HStack(spacing: 7) {
                                    Image(systemName: entry.hasSuffix("/") ? "folder.fill" : archiveEntryIcon(entry))
                                        .font(.system(size: 11))
                                        .foregroundStyle(archiveEntryColor(entry))
                                        .frame(width: 16)
                                    Text(entry)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 3)
                            }
                            if truncated {
                                Text("…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14).padding(.bottom, 6)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .onAppear { listContents() }
        .onChange(of: url) { listContents() }
    }

    private func listContents() {
        entries = []; failed = false; truncated = false
        let ext = url.pathExtension.lowercased()
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var isTruncated = false

            // ZIP and unzip-compatible formats
            if ["zip","docx","xlsx","pptx","pages","numbers","key","jar","ipa","apk","odt"].contains(ext) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                task.arguments = ["-l", url.path]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = Pipe()
                try? task.run(); task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                lines = output.components(separatedBy: "\n")
                    .dropFirst(3).dropLast(2)          // remove header and total
                    .compactMap { line -> String? in
                        let cols = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                        guard cols.count >= 4 else { return nil }
                        return String(cols[3])
                    }
            }
            // TAR / GZ / BZ2 / XZ / TGZ
            else if ["tar","gz","tgz","bz2","xz"].contains(ext) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                var args = ["-tf", url.path]
                if ext == "gz" || ext == "tgz" { args.insert("-z", at: 0) }
                else if ext == "bz2"           { args.insert("-j", at: 0) }
                else if ext == "xz"            { args.insert("-J", at: 0) }
                task.arguments = args
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = Pipe()
                try? task.run(); task.waitUntilExit()
                lines = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                    .components(separatedBy: "\n").filter { !$0.isEmpty }
            }
            // 7z / RAR
            else if ["7z","rar"].contains(ext) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/local/bin/7z")
                    .existingOrNil() ?? URL(fileURLWithPath: "/opt/homebrew/bin/7z")
                task.arguments = ["l", url.path]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = Pipe()
                try? task.run(); task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                lines = output.components(separatedBy: "\n")
                    .compactMap { line -> String? in
                        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                        guard cols.count >= 5, line.contains("-") || line.contains("D") else { return nil }
                        return cols.dropFirst(4).joined(separator: " ")
                    }
            }

            if lines.count > 200 { isTruncated = true; lines = Array(lines.prefix(200)) }
            if lines.isEmpty { DispatchQueue.main.async { failed = true }; return }
            DispatchQueue.main.async { entries = lines; truncated = isTruncated }
        }
    }

    private func archiveEntryIcon(_ name: String) -> String {
        if name.hasSuffix("/") { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift","py","js","ts","rb","go","rs","kt","java","c","cpp","h","m": return "chevron.left.forwardslash.chevron.right"
        case "png","jpg","jpeg","gif","webp","tiff","heic","svg":                  return "photo"
        case "mp4","mov","avi","mkv":                                              return "film"
        case "mp3","aac","wav","flac","m4a":                                       return "music.note"
        case "pdf":                                                                return "doc.richtext"
        case "json","yaml","yml","xml","toml":                                     return "curlybraces"
        case "txt","md","markdown":                                                return "doc.plaintext"
        case "zip","gz","tar","7z","rar":                                          return "archivebox"
        default:                                                                   return "doc"
        }
    }

    private func archiveEntryColor(_ name: String) -> Color {
        if name.hasSuffix("/") { return Color(red: 0.30, green: 0.60, blue: 0.95) }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                              return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "png","jpg","jpeg","gif","webp","heic": return Color(red: 0.75, green: 0.35, blue: 0.90)
        case "mp4","mov","avi","mkv":              return Color(red: 0.10, green: 0.45, blue: 0.90)
        case "mp3","aac","wav","m4a":              return Color(red: 0.90, green: 0.35, blue: 0.65)
        case "pdf":                                return Color(red: 0.88, green: 0.20, blue: 0.20)
        case "json","yaml","yml","xml":            return Color(red: 0.55, green: 0.20, blue: 0.90)
        default:                                   return Color.secondary
        }
    }
}

private extension URL {
    func existingOrNil() -> URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}

// MARK: - Fallback: file icon + name for unsupported types
private struct UnsupportedFilePreview: View {
    let url: URL

    var body: some View {
        let ext = url.pathExtension.lowercased()
        VStack(spacing: 16) {
            FileIconView(ext: ext, size: 90, radius: 24, fontSize: 38)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Text(L.file(ext: url.pathExtension.uppercased()))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dispatcher: chooses the appropriate preview based on file extension.
private struct FilePreview: View {
    let url: URL

    private var ext: String { url.pathExtension.lowercased() }

    private static let textExtensions: Set<String> = [
        "txt","md","markdown","swift","py","js","ts","jsx","tsx",
        "html","htm","css","scss","sass","less",
        "json","xml","yaml","yml","toml","ini","cfg","conf",
        "sh","bash","zsh","fish","rb","php","go","rs","kt","java","c","cpp","h","m"
    ]
    static let imageExtensions: Set<String> = [
        "png","jpg","jpeg","gif","webp","tiff","tif","bmp","heic","heif","svg"
    ]
    static let videoExtensions: Set<String> = [
        "mp4","mov","avi","mkv","m4v","wmv","flv","webm"
    ]
    /// Rich formats displayed via QLPreviewView (faithful document preview).
    private static let quickLookExtensions: Set<String> = [
        // Apple iWork
        "pages","numbers","key",
        // Microsoft Office
        "docx","doc","xlsx","xls","pptx","ppt","odt","ods","odp","rtf",
        // Adobe
        "psd","ai","indd","eps",
        // Sketch / Figma / others
        "sketch",
        // ePub / books
        "epub",
        // Audio
        "mp3","aac","wav","flac","m4a","aiff","ogg"
    ]
    /// Archives whose contents are displayed as a text list.
    private static let archiveExtensions: Set<String> = [
        "zip","tar","gz","tgz","bz2","xz","rar","7z",
        "jar","ipa","apk"
    ]

    var body: some View {
        Group {
            if ext == "pdf" {
                PDFPagesPreview(url: url)
            } else if Self.textExtensions.contains(ext) {
                TextFilePreview(url: url)
            } else if Self.imageExtensions.contains(ext) {
                ImageFilePreview(url: url)
            } else if Self.videoExtensions.contains(ext) {
                VideoFilePreview(url: url)
            } else if Self.quickLookExtensions.contains(ext) {
                QuickLookPreview(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if Self.archiveExtensions.contains(ext) {
                ArchivePreview(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            } else {
                UnsupportedFilePreview(url: url)
            }
        }
    }
}


// MARK: - File icon and color helper

/// Representation of a file icon: either an SF Symbol or a colored text badge (Adobe-style).
enum FileIcon {
    case symbol(String, Color)
    case badge(String, backgroundColor: Color, textColor: Color)
}

private func fileIcon(ext: String) -> FileIcon {
    switch ext {

    // ── PDF ──────────────────────────────────────────────────────────────────
    case "pdf":
        return .symbol("doc.richtext.fill", Color(red: 0.90, green: 0.15, blue: 0.10))

    // ── Adobe suite ──────────────────────────────────────────────────────────
    // Photoshop — dark bg #001E36, bright blue letters #31A8FF (matches official icon)
    case "psd", "psb":
        return .badge("Ps", backgroundColor: Color(red: 0.00, green: 0.12, blue: 0.21),
                           textColor: Color(red: 0.19, green: 0.66, blue: 1.00))
    // Illustrator — dark bg #330000, bright orange letters #FF9A00
    case "ai":
        return .badge("Ai", backgroundColor: Color(red: 0.20, green: 0.07, blue: 0.00),
                           textColor: Color(red: 1.00, green: 0.60, blue: 0.00))
    // InDesign — dark bg #49021F, bright pink letters #FF3366
    case "indd", "indb", "indt":
        return .badge("Id", backgroundColor: Color(red: 0.29, green: 0.01, blue: 0.12),
                           textColor: Color(red: 1.00, green: 0.20, blue: 0.40))
    // Premiere Pro — dark bg #00005B, light purple letters #9999FF
    case "prproj":
        return .badge("Pr", backgroundColor: Color(red: 0.00, green: 0.00, blue: 0.36),
                           textColor: Color(red: 0.60, green: 0.60, blue: 1.00))
    // After Effects — dark bg #1A0050, electric purple letters #9999FF
    case "aep", "aet":
        return .badge("Ae", backgroundColor: Color(red: 0.10, green: 0.00, blue: 0.31),
                           textColor: Color(red: 0.60, green: 0.60, blue: 1.00))
    // XD — dark bg #2B0040, bright pink letters #FF61F6
    case "xd":
        return .badge("Xd", backgroundColor: Color(red: 0.17, green: 0.00, blue: 0.25),
                           textColor: Color(red: 1.00, green: 0.38, blue: 0.96))
    // Lightroom Classic — dark bg #001122, Adobe blue letters #31A8FF
    case "lrcat", "lrtemplate", "lrsmcol":
        return .badge("Lr", backgroundColor: Color(red: 0.00, green: 0.07, blue: 0.13),
                           textColor: Color(red: 0.19, green: 0.66, blue: 1.00))
    // Animate — dark bg #1A0800, bright orange letters #ED6B25
    case "fla", "xfl":
        return .badge("An", backgroundColor: Color(red: 0.10, green: 0.03, blue: 0.00),
                           textColor: Color(red: 0.93, green: 0.42, blue: 0.15))
    // Audition — dark bg #001219, bright cyan letters #00E4BB
    case "sesx":
        return .badge("Au", backgroundColor: Color(red: 0.00, green: 0.07, blue: 0.10),
                           textColor: Color(red: 0.00, green: 0.89, blue: 0.73))
    // Dimension — dark bg #001A3A, bright blue letters #4DAEFF
    case "dn":
        return .badge("Dn", backgroundColor: Color(red: 0.00, green: 0.10, blue: 0.23),
                           textColor: Color(red: 0.30, green: 0.68, blue: 1.00))

    // ── Figma ────────────────────────────────────────────────────────────────
    // Figma — official purple/pink
    case "fig":
        return .badge("Fig", backgroundColor: Color(red: 0.65, green: 0.35, blue: 1.00),
                             textColor: .white)

    // ── Sketch ───────────────────────────────────────────────────────────────
    // Sketch — official yellow
    case "sketch":
        return .badge("Sk", backgroundColor: Color(red: 0.98, green: 0.73, blue: 0.17),
                           textColor: Color(red: 0.15, green: 0.12, blue: 0.00))

    // ── Blender / 3D ─────────────────────────────────────────────────────────
    case "blend", "blend1":
        return .badge("Bl", backgroundColor: Color(red: 1.00, green: 0.46, blue: 0.07),
                           textColor: .white)
    case "fbx":
        return .badge("FBX", backgroundColor: Color(red: 0.20, green: 0.55, blue: 0.85),
                             textColor: .white)
    case "obj":
        return .badge("OBJ", backgroundColor: Color(red: 0.45, green: 0.45, blue: 0.50),
                             textColor: .white)
    case "stl":
        return .badge("STL", backgroundColor: Color(red: 0.22, green: 0.68, blue: 0.72),
                             textColor: .white)
    case "gltf", "glb":
        return .badge("glTF", backgroundColor: Color(red: 0.53, green: 0.34, blue: 0.82),
                              textColor: .white)

    // ── Databases ────────────────────────────────────────────────────────────
    case "db", "sqlite", "sqlite3", "db3":
        return .symbol("cylinder.fill", Color(red: 0.40, green: 0.44, blue: 0.52))
    case "sql":
        return .badge("SQL", backgroundColor: Color(red: 0.25, green: 0.48, blue: 0.72),
                             textColor: .white)

    // ── Certificates / security ───────────────────────────────────────────────
    case "pem", "p12", "pfx", "cer", "crt":
        return .symbol("lock.shield.fill", Color(red: 0.18, green: 0.62, blue: 0.28))

    // ── Executables / macOS packages ──────────────────────────────────────────
    case "dmg":
        return .symbol("opticaldisc.fill", Color(red: 0.50, green: 0.52, blue: 0.56))
    case "pkg":
        return .symbol("shippingbox.fill", Color(red: 0.55, green: 0.38, blue: 0.18))
    case "app":
        return .symbol("app.fill", Color(red: 0.25, green: 0.50, blue: 0.92))

    // ── E-books ───────────────────────────────────────────────────────────────
    case "epub":
        return .symbol("book.fill", Color(red: 0.15, green: 0.58, blue: 0.30))
    case "mobi", "azw", "azw3":
        return .symbol("book.closed.fill", Color(red: 0.12, green: 0.50, blue: 0.25))

    // ── CAD / blueprints ──────────────────────────────────────────────────────
    case "dwg", "dxf":
        return .badge("DWG", backgroundColor: Color(red: 0.20, green: 0.38, blue: 0.62),
                             textColor: .white)
    case "step", "stp", "iges", "igs":
        return .badge("CAD", backgroundColor: Color(red: 0.30, green: 0.45, blue: 0.65),
                             textColor: .white)

    // ── Swift / compiled source code ──────────────────────────────────────────
    case "swift":
        return .symbol("swift", Color(red: 0.20, green: 0.78, blue: 0.35))
    case "c", "cpp", "h", "m", "mm":
        return .symbol("hammer.fill", Color(red: 0.18, green: 0.70, blue: 0.30))
    case "py":
        return .symbol("chevron.left.forwardslash.chevron.right", Color(red: 0.22, green: 0.72, blue: 0.38))
    case "js", "ts", "jsx", "tsx":
        return .symbol("function", Color(red: 0.25, green: 0.75, blue: 0.40))
    case "go":
        return .symbol("arrow.trianglehead.2.counterclockwise.rotate.90", Color(red: 0.20, green: 0.76, blue: 0.65))
    case "rs":
        return .symbol("gear.badge", Color(red: 0.62, green: 0.35, blue: 0.10))
    case "kt", "kts":
        return .symbol("k.circle.fill", Color(red: 0.45, green: 0.20, blue: 0.85))
    case "java":
        return .symbol("cup.and.heat.waves.fill", Color(red: 0.80, green: 0.30, blue: 0.10))
    case "rb":
        return .symbol("diamond.fill", Color(red: 0.85, green: 0.15, blue: 0.15))
    case "php":
        return .symbol("p.circle.fill", Color(red: 0.44, green: 0.46, blue: 0.80))
    case "dart":
        return .badge("Dt", backgroundColor: Color(red: 0.00, green: 0.57, blue: 0.80),
                          textColor: .white)
    case "lua":
        return .badge("Lua", backgroundColor: Color(red: 0.18, green: 0.20, blue: 0.55),
                             textColor: .white)
    case "r", "rmd":
        return .badge("R", backgroundColor: Color(red: 0.27, green: 0.48, blue: 0.72),
                         textColor: .white)

    // ── HTML / CSS ────────────────────────────────────────────────────────────
    case "html", "htm":
        return .symbol("globe", Color(red: 0.95, green: 0.45, blue: 0.05))
    case "css", "scss", "sass", "less":
        return .symbol("paintpalette.fill", Color(red: 0.95, green: 0.38, blue: 0.05))

    // ── JSON / YAML / config ──────────────────────────────────────────────────
    case "json":
        return .symbol("curlybraces", Color(red: 0.55, green: 0.20, blue: 0.90))
    case "yaml", "yml":
        return .symbol("list.bullet.indent", Color(red: 0.50, green: 0.18, blue: 0.85))
    case "toml", "ini", "cfg", "conf":
        return .symbol("gearshape.fill", Color(red: 0.48, green: 0.18, blue: 0.80))

    // ── Shell / scripts ───────────────────────────────────────────────────────
    case "sh", "bash", "zsh", "fish":
        return .symbol("terminal.fill", Color(red: 0.45, green: 0.48, blue: 0.52))

    // ── Archives ─────────────────────────────────────────────────────────────
    case "zip", "tar", "gz", "bz2", "xz", "rar", "7z":
        return .symbol("archivebox.fill", Color(red: 0.52, green: 0.34, blue: 0.20))

    // ── Video ─────────────────────────────────────────────────────────────────
    case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm":
        return .symbol("film.fill", Color(red: 0.10, green: 0.45, blue: 0.90))

    // ── Audio ─────────────────────────────────────────────────────────────────
    case "mp3", "aac", "wav", "flac", "ogg", "m4a", "aiff":
        return .symbol("music.note", Color(red: 0.90, green: 0.35, blue: 0.65))

    // ── Spreadsheet / Excel ───────────────────────────────────────────────────
    case "xlsx", "xls", "csv", "numbers":
        return .symbol("tablecells.fill", Color(red: 0.10, green: 0.52, blue: 0.22))

    // ── Word processing / Word ────────────────────────────────────────────────
    case "docx", "doc", "rtf", "odt":
        return .symbol("doc.text.fill", Color(red: 0.10, green: 0.28, blue: 0.72))

    // ── Pages (Apple) ─────────────────────────────────────────────────────────
    case "pages":
        return .symbol("doc.richtext", Color(red: 0.85, green: 0.70, blue: 0.05))

    // ── PowerPoint / Keynote ──────────────────────────────────────────────────
    case "pptx", "ppt":
        return .symbol("rectangle.on.rectangle.angled.fill", Color(red: 0.88, green: 0.30, blue: 0.05))

    // ── Keynote (Apple) ───────────────────────────────────────────────────────
    case "key":
        return .symbol("rectangle.on.rectangle.angled.fill", Color(red: 0.10, green: 0.46, blue: 0.95))

    // ── Plain text / Markdown ─────────────────────────────────────────────────
    case "txt":
        return .symbol("doc.plaintext.fill", Color(red: 0.40, green: 0.44, blue: 0.50))
    case "md", "markdown":
        return .symbol("doc.text", Color(red: 0.40, green: 0.44, blue: 0.50))

    // ── XML / SVG ─────────────────────────────────────────────────────────────
    case "xml":
        return .symbol("angle.left.and.angle.right.and.dot.point", Color(red: 0.55, green: 0.22, blue: 0.88))
    case "svg":
        return .symbol("skew", Color(red: 0.95, green: 0.42, blue: 0.05))

    // ── Fonts ─────────────────────────────────────────────────────────────────
    case "ttf", "otf", "woff", "woff2":
        return .symbol("textformat", Color(red: 0.60, green: 0.30, blue: 0.80))

    // ── Fallback ──────────────────────────────────────────────────────────────
    default:
        return .symbol("doc.fill", Color(red: 0.40, green: 0.44, blue: 0.50))
    }
}

/// Compatibility: returns (sfSymbol, color) for legacy call sites.
/// Badges use a generic symbol; FileIconView handles the full rendering.
private func fileIconAndColor(ext: String) -> (String, Color) {
    switch fileIcon(ext: ext) {
    case .symbol(let s, let c):            return (s, c)
    case .badge(_, let bgColor, _):        return ("doc.fill", bgColor)
    }
}

// MARK: - Unified file icon view (symbol or badge)

/// Replaces inline ZStacks in ClipboardItemRow and UnsupportedFilePreview.
private struct FileIconView: View {
    let ext: String
    /// Square container size (e.g. 36 for list, 90 for preview).
    let size: CGFloat
    /// Corner radius (e.g. 20 for list, 24 for preview).
    let radius: CGFloat
    /// Icon font size (e.g. 15 for list, 38 for preview).
    let fontSize: CGFloat
    /// If true, more opaque background + white text (selected state in list).
    var isSelected: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// In light mode, vivid colors on a white background become invisible at 0.18 opacity;
    /// we increase the background opacity and darken the icon with a multiplier.
    private var isLight: Bool { colorScheme == .light }

    /// Symbol background opacity: higher in light mode to compensate for the white background.
    private var symbolBackgroundOpacity: Double {
        if isSelected { return 0.40 }
        return isLight ? 0.16 : 0.18
    }

    /// The icon color is darkened in light mode (×0.65 per component)
    /// to remain legible on a white background.
    private func adaptedColor(_ color: Color) -> Color {
        guard isLight, !isSelected else { return color }
        guard let components = NSColor(color).usingColorSpace(.sRGB) else { return color }
        return Color(
            red:   components.redComponent   * 0.62,
            green: components.greenComponent * 0.62,
            blue:  components.blueComponent  * 0.62
        )
    }

    var body: some View {
        let icon = fileIcon(ext: ext)
        ZStack {
            switch icon {
            case .symbol(let name, let color):
                let adapted = adaptedColor(color)
                RoundedRectangle(cornerRadius: radius)
                    .fill(adapted.opacity(symbolBackgroundOpacity))
                Image(systemName: name)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(isSelected ? .white : adapted)

            case .badge(let text, let bgColor, let labelColor):
                // Badges already have an opaque dark background — left as-is.
                RoundedRectangle(cornerRadius: radius)
                    .fill(bgColor.opacity(isSelected ? 0.85 : 0.92))
                Text(text)
                    .font(.system(size: fontSize * 0.72, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : labelColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Image file URL thumbnail

private struct FileThumbnailURL: View {
    let url: URL
    let loadImmediately: Bool

    // Shared cache across all instances
    private static let cache = NSCache<NSURL, NSImage>()

    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
                    .overlay(loadImmediately ? AnyView(ProgressView().scaleEffect(0.5)) : AnyView(EmptyView()))
            }
        }
        .onAppear { if loadImmediately { load() } }
        .onChange(of: loadImmediately) { if loadImmediately { load() } }
    }

    private func load() {
        guard image == nil else { return }
        // Check the cache first
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: url) else { return }
            Self.cache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async { image = img }
        }
    }
}

// MARK: - Video thumbnail (AVFoundation, lazy + shared cache)

private struct VideoThumbnailURL: View {
    let url: URL
    let loadImmediately: Bool

    // Shared cache across all instances — same pattern as FileThumbnailURL
    private static let cache = NSCache<NSURL, NSImage>()

    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    if loadImmediately {
                        ProgressView().scaleEffect(0.5)
                    }
                }
            }
        }
        .onAppear { if loadImmediately { load() } }
        .onChange(of: loadImmediately) { if loadImmediately { load() } }
    }

    private func load() {
        guard image == nil else { return }
        // Cache first — no work if already extracted
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached; return
        }
        DispatchQueue.global(qos: .utility).async {
            guard let img = VideoThumbnailURL.extractFrame(from: url) else { return }
            Self.cache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async { image = img }
        }
    }

    /// Extracts the first usable frame (at t = 0.5 s or t = 0 for short files).
    /// All work is on a background thread — never on the main thread.
    /// `maxSize`: maximum dimension of the longest side in physical pixels.
    /// Pass 120 for list thumbnails, the actual view size for the preview.
    /// AVAssetImageGenerator never decodes more pixels than necessary.
    static func extractFramePublic(from url: URL, maxSize: CGFloat = 120) -> NSImage? {
        extractFrame(from: url, maxSize: maxSize)
    }

    private static func extractFrame(from url: URL, maxSize: CGFloat = 120) -> NSImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // respects video rotation
        // Limit decoding to the actual view size — never full resolution.
        // A 4K video in a 400 px window is decoded at 400 px max, not 4K.
        let cap = max(maxSize, 1)
        generator.maximumSize = CGSize(width: cap, height: cap)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImg, size: .zero)
    }
}

// MARK: - Item row

struct ClipboardItemRow: View {
    let element: ClipboardItem
    let isSelected: Bool
    var sequenceIndex: Int? = nil
    var loadThumbnail: Bool = true
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if case .image(let img) = element.content {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else if case .text = element.content, let color = element.cachedColor {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(color)
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                } else if case .fileURL(let url) = element.content {
                    let ext            = url.pathExtension.lowercased()
                    let isImageFile    = FilePreview.imageExtensions.contains(ext)
                    let isVideoFile    = FilePreview.videoExtensions.contains(ext)
                    if isImageFile {
                        FileThumbnailURL(url: url, loadImmediately: loadThumbnail)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    } else if isVideoFile {
                        VideoThumbnailURL(url: url, loadImmediately: loadThumbnail)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    } else {
                        FileIconView(ext: ext, size: 36, radius: 20, fontSize: 15,
                                        isSelected: isSelected)
                    }
                } else if case .text(let t) = element.content, t.hasPrefix("http") || t.hasPrefix("www") {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.blue.opacity(isSelected ? 0.4 : 0.2))
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? .white : Color.blue)
                    }
                    .frame(width: 36, height: 36)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(element.typeColor.opacity(isSelected ? 0.4 : 0.2))
                        Image(systemName: element.typeIcon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? .white : element.typeColor)
                    }
                    .frame(width: 36, height: 36)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(element.displayTitle)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                Group {
                    if case .fileURL(let url) = element.content, !url.pathExtension.isEmpty {
                        Text(url.pathExtension.uppercased())
                    } else if case .text = element.content, element.cachedColor != nil {
                        Text(L.color)
                    } else {
                        Text(element.typeLabel)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            Spacer()
            if let idx = sequenceIndex {
                ZStack {
                    Circle().fill(Color.accentAttenuation).frame(width: 18, height: 18)
                    Text("\(idx)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20).fill(
                isSelected ? Color.accentAttenuation :
                isHovered  ? Color.primary.opacity(0.07) : Color.clear
            )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
        .simultaneousGesture(TapGesture(count: 1).onEnded { onTap() })
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: element.isPinned)
    }
}

// MARK: - Shared confirm button logic

private struct ConfirmButton<Label: View>: View {
    let helpText: String
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label

    @State private var showConfirmed = false

    var body: some View {
        Button {
            guard !showConfirmed else { return }
            action()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { showConfirmed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showConfirmed = false }
            }
        } label: {
            label(showConfirmed)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled(showConfirmed)
    }
}

// MARK: - Action buttons

private struct AnimatedActionButton: View {
    let title: String
    let icon: String?
    let helpText: String
    let fullWidth: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        ConfirmButton(helpText: helpText, action: action) { confirmed in
            ZStack {
                // Visible content: icon only when confirmed, icon + text otherwise
                if confirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 6) {
                        if let icon { Image(systemName: icon) }
                        if !title.isEmpty { Text(title) }
                    }
                    .transition(.opacity)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            // Fixed height matching SaveImageButton to avoid layout shift
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34, maxHeight: 34)
            .padding(.horizontal, fullWidth ? 0 : 12)
            .background(
                confirmed ? Color.green : (isHovered ? Color.accentAttenuation.opacity(0.75) : Color.accentAttenuation),
                in: RoundedRectangle(cornerRadius: 26)
            )
        }
        .onHover { isHovered = $0 }
    }
}

private struct HoverIconButton: View {
    let symbol: String
    let color: Color
    let helpText: String
    let action: () -> Void

    @State private var isHovered  = false
    @State private var isPressed  = false

    // Red if the passed color is red (delete button)
    private var isRed: Bool { color == .red }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) { isPressed = true }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isPressed = false }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRed
                    ? Color.red
                    : (isHovered ? Color.accentColor : Color.secondary))
                .frame(width: 36, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 26).fill(isRed
                        ? (isHovered ? Color.red.opacity(0.15) : Color.primary.opacity(0.06))
                        : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Item pin button (with pin animation)

private struct ItemPinButton: View {
    let isPinned: Bool
    let action: () -> Void

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var rotation:  Double = 0
    @State private var scale:     CGFloat = 1

    init(isPinned: Bool, action: @escaping () -> Void) {
        self.isPinned = isPinned
        self.action   = action
        self._rotation = State(initialValue: isPinned ? 45 : 0)
    }

    var body: some View {
        Button {
            let pinning = !isPinned
            if pinning {
                withAnimation(.interpolatingSpring(stiffness: 280, damping: 14)) {
                    rotation = 45
                    scale    = 1.25
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { scale = 1.0 }
                }
            } else {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    rotation = 0
                    scale    = 0.85
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { scale = 1.0 }
                }
            }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) { isPressed = true }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isPressed = false }
            }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPinned ? Color.accentColor : (isHovered ? Color.accentColor : Color.secondary))
                .rotationEffect(.degrees(rotation))
                .scaleEffect(scale)
                .frame(width: 36, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 26).fill(isPinned
                        ? Color.accentColor.opacity(0.15)
                        : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
                .animation(.interpolatingSpring(stiffness: 280, damping: 14), value: scale)
        }
        .buttonStyle(.plain)
        .help(isPinned ? L.pinItem : L.pinItem)
        .onHover { isHovered = $0 }
        .onChange(of: isPinned) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.80)) {
                rotation = isPinned ? 45 : 0
            }
        }
    }
}

// MARK: - Image save button

private struct SaveImageButton: View {
    let image: NSImage
    @State private var isHovered = false

    var body: some View {
        ConfirmButton(helpText: "Save image to Desktop", action: saveToDesktop) { confirmed in
            Group {
                if confirmed {
                    Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(confirmed ? .white : (isHovered ? Color.accentColor : Color.secondary))
            .frame(width: 36, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 26).fill(confirmed
                    ? Color.green
                    : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }

    private func saveToDesktop() {
        guard let data = pngData(from: image) else { return }
        let desktop  = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let fileName = "Clipboard_\(DateFormatter.timeOnly.string(from: Date())).png"
        try? data.write(to: desktop.appendingPathComponent(fileName))
    }
}

// MARK: - File save button (URL → Desktop)

private struct SaveFileButton: View {
    let url: URL
    @State private var isHovered = false

    var body: some View {
        ConfirmButton(helpText: "Save file to Desktop", action: saveToDesktop) { confirmed in
            Group {
                if confirmed {
                    Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(confirmed ? .white : (isHovered ? Color.accentColor : Color.secondary))
            .frame(width: 36, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 26).fill(confirmed
                    ? Color.green
                    : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }

    private func saveToDesktop() {
        let desktop     = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let destination = desktop.appendingPathComponent(url.lastPathComponent)
        var dest    = destination
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            dest = desktop.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}



// Application icon removed — replaced by plain text name only

private struct SegmentedFilterControl: View {
    let filters: [ClipboardFilter]
    @Binding var activeFilter: ClipboardFilter
    var iconsOnly: Bool = false

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(filters.count)
            let index = CGFloat(filters.firstIndex(of: activeFilter) ?? 0)
            let segmentWidth  = geo.size.width / count
            let segmentHeight = geo.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .frame(width: segmentWidth, height: segmentHeight)
                    .offset(x: index * segmentWidth)
                    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: activeFilter)

                HStack(spacing: 0) {
                    ForEach(filters, id: \.self) { filter in
                        SegmentButton(filter: filter, isActive: activeFilter == filter,
                                      width: segmentWidth, height: segmentHeight, iconsOnly: iconsOnly) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { activeFilter = filter }
                        }
                    }
                }
            }
        }
        .frame(height: 32)
    }
}

private struct SegmentButton: View {
    let filter: ClipboardFilter
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat
    var iconsOnly: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if iconsOnly {
                    Image(systemName: filter.icon)
                        .font(.system(size: 10, weight: .medium))
                } else if isActive {
                    Text(filter.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .center)))
                } else {
                    Image(systemName: filter.icon)
                        .font(.system(size: 10, weight: .medium))
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .center)))
                }
            }
            .foregroundStyle(isActive ? .primary : (isHovered ? .primary : .secondary))
            .padding(.horizontal, 6)
            .frame(width: width, height: height)
            .background(
                isHovered && !isActive
                    ? RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.06))
                    : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isActive)
    }
}

// MARK: - Shared CGEvent tap (blocking, session level)
//
// Why CGEvent tap instead of LocalMonitor / GlobalMonitor?
// • .nonactivatingPanel makes makeKey() inoperative → LocalMonitor receives nothing.
// • GlobalMonitor receives key presses but cannot block them: they also
//   reach the background app (double keystroke).
// • CGEvent tap operates upstream of all window dispatch. Returning nil
//   in the callback permanently suppresses the event — even with
//   .nonactivatingPanel, regardless of which window is keyWindow.
//   This is the same mechanism used for the open shortcut.

private enum ActiveKeyboardTap {
    /// Installs a blocking CGEvent tap for keyDown events.
    /// - parameter handler: called on the main thread with the corresponding NSEvent.
    /// - returns: opaque wrapper to pass to `remove(_:)` for cleanup.
    static func install(handler: @escaping (NSEvent) -> Void) -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // Store the handler in a box to pass it via refcon (UnsafeMutableRawPointer).
        let box    = HandlerBox(handler)
        let refcon = Unmanaged.passRetained(box).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, cgEvent, refcon -> Unmanaged<CGEvent>? in
                guard let refcon,
                      let nsEvent = NSEvent(cgEvent: cgEvent) else {
                    return Unmanaged.passRetained(cgEvent)
                }
                let box = Unmanaged<HandlerBox>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { box.handler(nsEvent) }
                return nil   // blocks the event — it reaches no other window
            },
            userInfo: refcon
        ) else {
            Unmanaged<HandlerBox>.fromOpaque(refcon).release()
            return nil
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    /// Disables and releases the tap returned by `install`.
    static func remove(_ tap: CFMachPort?) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    // Box to carry the Swift closure through the C refcon.
    private final class HandlerBox {
        let handler: (NSEvent) -> Void
        init(_ h: @escaping (NSEvent) -> Void) { handler = h }
    }
}

// MARK: - Search button

private struct SearchButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
    }
}

// MARK: - Inline search field (replaces the filter bar)

private struct InlineSearchField: View {
    @Binding var text: String
    @Binding var isActive: Bool

    @State private var cursorVisible:    Bool = true
    @State private var cursorTimer:      Timer? = nil
    @State private var keyboardMonitor:  CFMachPort? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(S("Search…", "Search…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 0) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: 14)
                        .opacity(cursorVisible ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Cross: clears text if text is present, otherwise closes the field
            Button {
                if text.isEmpty { close() } else { text = "" }
            } label: {
                Image(systemName: text.isEmpty ? "xmark" : "xmark.circle.fill")
                    .font(.system(size: text.isEmpty ? 10 : 12, weight: text.isEmpty ? .semibold : .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity)
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            text     = ""
            isActive = false
        }
    }

    private func installMonitor() {
        cursorVisible = true
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async { cursorVisible.toggle() }
        }

        // Blocking CGEvent tap: intercepts keyDown events before any dispatch.
        // Returning nil in the callback blocks the event — it never reaches the background app.
        // This is the only reliable solution with .nonactivatingPanel:
        //   • LocalMonitor receives nothing because makeKey() is inoperative on .nonactivatingPanel.
        //   • GlobalMonitor receives key presses but cannot block them (double keystroke).
        keyboardMonitor = ActiveKeyboardTap.install(handler: { event in
            handleEvent(event)
        })
    }

    private func removeMonitor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        ActiveKeyboardTap.remove(keyboardMonitor)
        keyboardMonitor = nil
    }

    private func handleEvent(_ event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        if event.keyCode == 51 { if !text.isEmpty { text = String(text.dropLast()) }; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty { return }
        if let chars = event.characters {
            let filtered = chars.filter { !$0.isNewline && $0 != "\t" && $0.asciiValue ?? 0 >= 32 }
            if !filtered.isEmpty { text += filtered }
        }
    }
}

// MARK: - Reset button

private struct ResetButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var rotation: Double = 0

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { rotation -= 360 }
            action()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
                .rotationEffect(.degrees(rotation))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(isHovered ? Color.red.opacity(0.15) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(L.clearHistory)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
    }
}

// MARK: - Color picker (screen color sampler)

/// Builds a cursor matching the reference design:
/// - Thick colored ring (outer) showing the detected color
/// - Semi-transparent dark interior (20% black) to see content underneath
/// - Small clean crosshair at the center
private func createMagnifierCursor(color: NSColor?) -> NSCursor {
    // Total canvas size (in points). macOS cursors are rendered at 2× on Retina.
    let size: CGFloat = 52
    let scale: CGFloat = 2          // explicit Retina scale for crisp rendering
    let pixelSize = size * scale

    let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize),
        pixelsHigh: Int(pixelSize),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)!
    ctx.cgContext.scaleBy(x: scale, y: scale)
    NSGraphicsContext.current = ctx

    let cg = ctx.cgContext
    let cx = size / 2
    let cy = size / 2

    // ── Dimensions ───────────────────────────────────────────────
    let outerRing:       CGFloat = 24   // outer edge of the colored ring
    let innerRing:       CGFloat = 16   // inner edge of the ring / outer edge of the dark zone
    let crosshairLength: CGFloat = 4    // half-length of each crosshair arm
    let crosshairGap:    CGFloat = 2    // gap between arm and center

    // ── 1. Colored ring (detected color, full opacity) ─────────
    let ringColor = (color ?? NSColor(white: 0.75, alpha: 1))
        .usingColorSpace(.sRGB) ?? NSColor(white: 0.75, alpha: 1)

    // Draw a full circle then cut out the inner circle
    cg.setFillColor(ringColor.cgColor)
    cg.addArc(center: CGPoint(x: cx, y: cy),
              radius: outerRing, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.fillPath()

    // ── 2. Thin dark border around the ring for contrast ─────────
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.40).cgColor)
    cg.setLineWidth(1.0)
    // Outer border
    cg.addArc(center: CGPoint(x: cx, y: cy),
              radius: outerRing - 0.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()
    // Inner border of the ring
    cg.addArc(center: CGPoint(x: cx, y: cy),
              radius: innerRing + 0.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    // ── 3. Fully transparent interior — punch a true hole with clear blend mode ──
    cg.setBlendMode(.clear)
    cg.addArc(center: CGPoint(x: cx, y: cy),
              radius: innerRing, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.fillPath()
    cg.setBlendMode(.normal)

    // ── 4. Small crosshair in the dark zone ──────────────────────
    // White with slight shadow for legibility on any background
    let crosshairColor = NSColor.white.withAlphaComponent(0.90).cgColor
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.setLineWidth(2.5)   // shadow pass
    // Horizontal
    cg.move(to: CGPoint(x: cx - crosshairLength - crosshairGap, y: cy))
    cg.addLine(to: CGPoint(x: cx - crosshairGap, y: cy))
    cg.move(to: CGPoint(x: cx + crosshairGap, y: cy))
    cg.addLine(to: CGPoint(x: cx + crosshairLength + crosshairGap, y: cy))
    // Vertical
    cg.move(to: CGPoint(x: cx, y: cy - crosshairLength - crosshairGap))
    cg.addLine(to: CGPoint(x: cx, y: cy - crosshairGap))
    cg.move(to: CGPoint(x: cx, y: cy + crosshairGap))
    cg.addLine(to: CGPoint(x: cx, y: cy + crosshairLength + crosshairGap))
    cg.strokePath()

    cg.setStrokeColor(crosshairColor)
    cg.setLineWidth(1.5)   // foreground pass
    // Horizontal
    cg.move(to: CGPoint(x: cx - crosshairLength - crosshairGap, y: cy))
    cg.addLine(to: CGPoint(x: cx - crosshairGap, y: cy))
    cg.move(to: CGPoint(x: cx + crosshairGap, y: cy))
    cg.addLine(to: CGPoint(x: cx + crosshairLength + crosshairGap, y: cy))
    // Vertical
    cg.move(to: CGPoint(x: cx, y: cy - crosshairLength - crosshairGap))
    cg.addLine(to: CGPoint(x: cx, y: cy - crosshairGap))
    cg.move(to: CGPoint(x: cx, y: cy + crosshairGap))
    cg.addLine(to: CGPoint(x: cx, y: cy + crosshairLength + crosshairGap))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()

    // Compose the final NSImage from the bitmap rep
    let img = NSImage(size: NSSize(width: size, height: size))
    img.addRepresentation(bitmapRep)

    // Hot spot exactly at the center
    return NSCursor(image: img, hotSpot: NSPoint(x: size / 2, y: size / 2))
}

private final class ColorPickerState: ObservableObject {
    @Published var isSelecting:   Bool = false
    @Published var currentColor:  NSColor? = nil

    private var trackingTimer: Timer?
    private var moveMonitor:   Any?

    // Blocking CGEvent tap — replaces the globalClickMonitor to
    // intercept left clicks and cancel them before they reach the target app.
    private var clickTap:            CFMachPort?
    private var clickRunLoopSource:  CFRunLoopSource?

    // Callback passed to startSelection, stored so the tap can call it.
    private var selectionCallback: ((NSColor) -> Void)?

    func startSelection(onSelection: @escaping (NSColor) -> Void) {
        isSelecting       = true
        selectionCallback = onSelection
        updateCursor(for: nil)

        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.samplePixel()
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, self.isSelecting else { return }
            self.updateCursor(for: self.currentColor)
        }
        installClickTap()
    }

    func stopSelection() {
        isSelecting       = false
        selectionCallback = nil
        trackingTimer?.invalidate(); trackingTimer = nil
        if let monitor = moveMonitor { NSEvent.removeMonitor(monitor); moveMonitor = nil }
        removeClickTap()
        NSCursor.arrow.set()
    }

    // MARK: - Blocking CGEvent tap

    private func installClickTap() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,   // head of the chain to intercept before everyone else
            options: .defaultTap,          // blocking mode (not listenOnly)
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let state = Unmanaged<ColorPickerState>.fromOpaque(refcon).takeUnretainedValue()
                guard state.isSelecting else { return Unmanaged.passRetained(event) }
                // Capture color and callback BEFORE stopSelection (which resets them to nil).
                let color    = state.currentColor
                let callback = state.selectionCallback
                DispatchQueue.main.async {
                    state.stopSelection()
                    if let color, let callback { callback(color) }
                }
                return nil   // ← blocks the event, the app underneath does not receive it
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            // No Accessibility permission — fall back to passive monitor
            let fallback = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let color = self.currentColor else { self?.stopSelection(); return }
                    self.stopSelection()
                    self.selectionCallback?(color)
                }
            }
            _ = fallback   // silent, cannot block without the tap
            return
        }

        clickTap           = tap
        clickRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), clickRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeClickTap() {
        if let tap = clickTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = clickRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            clickTap           = nil
            clickRunLoopSource = nil
        }
    }

    private func updateCursor(for color: NSColor?) {
        createMagnifierCursor(color: color).set()
    }

    /// Samples the pixel under the cursor.
    /// Uses CGDisplayCreateImage (non-deprecated) rather than CGWindowListCreateImage.
    private func samplePixel() {
        let pos           = NSEvent.mouseLocation
        let displayID     = CGMainDisplayID()
        let displayHeight = CGFloat(CGDisplayPixelsHigh(displayID))
        let rect          = CGRect(x: Int(pos.x), y: Int(displayHeight - pos.y), width: 1, height: 1)

        guard let img   = CGDisplayCreateImage(displayID, rect: rect),
              let color = NSBitmapImageRep(cgImage: img).colorAt(x: 0, y: 0) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentColor = color
            if self.isSelecting { self.updateCursor(for: color) }
        }
    }
}

private struct ColorPickerButton: View {
    let monitor: ClipboardMonitor
    let close: () -> Void
    /// If provided, called INSTEAD of close() when the panel is pinned —
    /// hides without destroying the panel so it can be reopened after.
    var hideForPicker: (() -> Void)? = nil
    /// Called after color selection to reopen the panel if it was pinned.
    var reopenAfterPicker: (() -> Void)? = nil
    @StateObject private var pickerState = ColorPickerState()
    @State private var isHovered = false

    var body: some View {
        Button {
            if pickerState.isSelecting {
                pickerState.stopSelection()
            } else {
                // If a temporary hide is available (pinned panel), use it;
                // otherwise close normally.
                let hideAction = hideForPicker ?? close
                hideAction()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pickerState.startSelection { color in
                        guard let rgb = color.usingColorSpace(.sRGB) else { return }
                        let r = Int(rgb.redComponent   * 255)
                        let g = Int(rgb.greenComponent * 255)
                        let b = Int(rgb.blueComponent  * 255)
                        let hex     = String(format: "#%02X%02X%02X", r, g, b)
                        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Color Picker"
                        let item    = ClipboardItem(content: .text(hex), source: appName, date: Date())
                        monitor.items.insert(item, at: 0)
                        monitor.copyToClipboard(item: item)
                        // Reopen the panel if it was pinned
                        reopenAfterPicker?()
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pickerState.isSelecting ? "stop.circle.fill" : "eyedropper")
                    .font(.system(size: 10, weight: .medium))
                Text(pickerState.isSelecting ? L.cancelColorPicker : L.colorPicker)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(pickerState.isSelecting ? Color.red : (isHovered ? .primary : .secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                pickerState.isSelecting
                    ? Color.red.opacity(0.08)
                    : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .help(pickerState.isSelecting ? L.colorPickerActiveHint : L.colorPickerStartHint)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Hoverable button helper for SequenceBar

private struct HoverableSequenceButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label(isHovered) }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Panel pin button (keeps the window open on focus change)

private struct PanelPinButton: View {
    @Binding var isPinned: Bool
    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var rotation:  Double = 0
    @State private var scale:     CGFloat = 1

    var body: some View {
        Button {
            let pinning = !isPinned
            // Animation: rotation + bounce when pinning, smooth return when unpinning
            if pinning {
                withAnimation(.interpolatingSpring(stiffness: 280, damping: 14)) {
                    rotation = 45
                    scale    = 1.25
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                        scale = 1.0
                    }
                }
            } else {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    rotation = 0
                    scale    = 0.85
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                        scale = 1.0
                    }
                }
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.80)) {
                isPinned = pinning
            }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) { isPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isPressed = false }
            }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPinned ? Color.accentColor : (isHovered ? Color.accentColor : Color.secondary))
                .rotationEffect(.degrees(rotation))
                .scaleEffect(scale)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(isPinned
                        ? Color.accentColor.opacity(0.15)
                        : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
                .animation(.interpolatingSpring(stiffness: 280, damping: 14), value: scale)
        }
        .buttonStyle(.plain)
        .help(isPinned
              ? S("Désépingler la fenêtre", "Unpin window")
              : S("Épingler la fenêtre (reste ouverte au changement d'app)", "Pin window (stays open when switching apps)"))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Multi-paste button

private struct MultiPasteButton: View {
    @Binding var isActive: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { isActive = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.number").font(.system(size: 10, weight: .medium))
                Text(L.multiPaste).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Sequence bar

private struct SequenceBar: View {
    @ObservedObject var monitor: ClipboardMonitor
    let close: () -> Void
    @Binding var isActive: Bool
    @Binding var queue: [ClipboardItem]
    var hideForPicker: (() -> Void)? = nil
    var reopenAfterPicker: (() -> Void)? = nil
    var hideForSequence: (() -> Void)? = nil
    var reopenAfterSequence: (() -> Void)? = nil
    @State private var panelHiddenForSequence: Bool = false

    private var isPending:    Bool { monitor.isSequenceActive }
    private var currentIndex: Int  { monitor.sequenceProgress.current }
    private var total:        Int  { monitor.sequenceQueue.count }

    var body: some View {
        Group {
            if isActive || isPending {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isPending ? Color.orange : Color.accentAttenuation)
                        .frame(width: 6, height: 6)

                    if isPending {
                        HStack(spacing: 4) {
                            ForEach(Array(monitor.sequenceQueue.enumerated()), id: \.element.id) { idx, _ in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        idx < currentIndex  ? Color.green.opacity(0.7) :
                                        idx == currentIndex ? Color.accentAttenuation :
                                                              Color.primary.opacity(0.15)
                                    )
                                    .frame(width: idx == currentIndex ? 18 : 10, height: 6)
                                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: currentIndex)
                            }
                        }
                        Text("\u{2318}V  \(currentIndex)/\(total)")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                        Spacer()
                        Button(action: cancel) {
                            Text(L.cancel)
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(queue.isEmpty ? L.tapToAdd : L.itemCount(queue.count))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(queue.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        if !queue.isEmpty {
                            HoverableSequenceButton {
                                queue = []
                            } label: { hovered in
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(hovered ? .primary : .secondary)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        hovered ? Color.primary.opacity(0.13) : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                            .fixedSize()
                            HoverableSequenceButton(action: start) { hovered in
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill").font(.system(size: 9))
                                    Text(L.start).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(
                                    hovered ? Color.accentAttenuation.opacity(0.75) : Color.accentAttenuation,
                                    in: RoundedRectangle(cornerRadius: 20)
                                )
                            }
                            .fixedSize()
                        }
                        HoverableSequenceButton(action: cancel) { hovered in
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(hovered ? .primary : .secondary)
                                .frame(width: 18, height: 18)
                                .background(
                                    hovered ? Color.primary.opacity(0.13) : Color.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                .background(
                    isPending ? Color.orange.opacity(0.08) : Color.accentAttenuation.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 8) {
                    MultiPasteButton(isActive: $isActive)

                    ColorPickerButton(monitor: monitor, close: close, hideForPicker: hideForPicker, reopenAfterPicker: reopenAfterPicker).frame(maxWidth: .infinity)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isPending)
        .onChange(of: monitor.isSequenceActive) { _, active in
            // Sequence just ended and the panel was hidden → reopen it
            if !active, panelHiddenForSequence {
                panelHiddenForSequence = false
                queue    = []
                isActive = false
                reopenAfterSequence?()
            }
        }
    }

    private func start() {
        guard !queue.isEmpty else { return }
        monitor.startSequence(items: queue)
        if let _ = hideForSequence {
            // Pinned panel: hide without destroying, will be reopened when done
            hideForSequence!()
            panelHiddenForSequence = true
        } else {
            close()
        }
    }

    private func cancel() {
        monitor.cancelSequence()
        queue    = []
        isActive = false
    }
}

// MARK: - Main panel

struct ClipboardPanel: View {
    @ObservedObject var monitor: ClipboardMonitor
    let close: () -> Void
    /// Passed only by the NSPanel — absent from the widget SDK panel
    var pinBinding: Binding<Bool>? = nil
    /// Hides the panel without destroying it (for the color picker when pinned)
    var hideForPicker: (() -> Void)? = nil
    /// Callback to reopen the panel after the color picker if pinned
    var reopenAfterPicker: (() -> Void)? = nil
    /// Hides the panel without destroying it (for the sequence when pinned)
    var hideForSequence: (() -> Void)? = nil
    /// Callback to reopen the panel after the sequence if pinned
    var reopenAfterSequence: (() -> Void)? = nil

    private var showPinButton: Bool { pinBinding != nil }

    @State private var selected:          ClipboardItem? = nil
    @State private var activeFilter:      ClipboardFilter = .all
    @State private var showSequencePanel: Bool = false
    @State private var sequenceQueue:     [ClipboardItem] = []
    @State private var searchActive:      Bool = false
    @State private var searchText:        String = ""

    private var filteredItems: [ClipboardItem] {
        let base: [ClipboardItem]
        switch activeFilter {
        case .all:   base = monitor.items
        case .media: base = monitor.items.filter {
            if case .image = $0.content { return true }
            if case .fileURL(let url) = $0.content {
                let ext = url.pathExtension.lowercased()
                let mediaExtensions: Set<String> = [
                    "jpg","jpeg","png","gif","webp","svg","tiff","tif","bmp","heic","heif",
                    "mp4","mov","avi","mkv","m4v","wmv","webm",
                    "pdf","docx","doc","xlsx","xls","pptx","ppt","pages","numbers","key","odt"
                ]
                return mediaExtensions.contains(ext)
            }
            return false
        }
        case .data: base = monitor.items.filter {
            if case .text = $0.content {
                let subtype = $0.cachedSubtype
                return subtype == .email || subtype == .phone || subtype == .date || subtype == .url
            }
            return false
        }
        }
        // Apply text search on top of the active filter
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { $0.displayTitle.lowercased().contains(query) }
    }

    private var pinnedItems:   [ClipboardItem] { filteredItems.filter { $0.isPinned } }
    private var unpinnedItems: [ClipboardItem] { filteredItems.filter { !$0.isPinned } }

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                // Fix: always read the item from monitor.items so that isPinned and other
                // state changes are immediately reflected (avoids stale struct copy).
                if let element = (selected.flatMap { s in monitor.items.first(where: { $0.id == s.id }) })
                                ?? monitor.items.first { previewPanel(element).id(element.id) }
                else { emptyPreview }
            }
            .padding(.leading, 304)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if searchActive {
                        // ── Search mode: text field replaces the filters ──
                        InlineSearchField(text: $searchText, isActive: $searchActive)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                                removal:   .scale(scale: 0.85, anchor: .leading).combined(with: .opacity)
                            ))
                    } else {
                        // ── Normal mode: filters + search button ───────────
                        SegmentedFilterControl(filters: ClipboardFilter.allCases, activeFilter: $activeFilter, iconsOnly: showPinButton)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity),
                                removal:   .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
                            ))
                        SearchButton {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                searchActive = true
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                    if let binding = pinBinding {
                        PanelPinButton(isPinned: binding)
                    }
                    ResetButton {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { monitor.clearAll(); selected = nil }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 7) {
                        if !pinnedItems.isEmpty {
                            sectionLabel(L.pinned)
                            ForEach(pinnedItems) { element in
                                itemRow(element)
                                    .id(element.id.uuidString + "\(element.isPinned)")
                                    .transition(.opacity)
                            }
                        }
                        if !unpinnedItems.isEmpty {
                            if !pinnedItems.isEmpty { sectionLabel(L.recent) }
                            ForEach(unpinnedItems) { element in
                                itemRow(element)
                                    .id(element.id.uuidString + "\(element.isPinned)")
                                    .transition(.opacity)
                            }
                        }
                        if filteredItems.isEmpty { emptyStateView }
                        Spacer().frame(height: 12)
                    }
                    .animation(.easeInOut(duration: 0.18), value: activeFilter)
                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 10)
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .allowsHitTesting(false)
                        .blendMode(.destinationOut)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black, .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 20)
                        .allowsHitTesting(false)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

                SequenceBar(monitor: monitor, close: close, isActive: $showSequencePanel, queue: $sequenceQueue,
                              hideForPicker: hideForPicker, reopenAfterPicker: reopenAfterPicker,
                              hideForSequence: hideForSequence, reopenAfterSequence: reopenAfterSequence)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .frame(width: 277).frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .padding(12)
        }
        .frame(width: 765, height: 500)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .onAppear { selected = monitor.items.first(where: { !$0.isPinned }) ?? monitor.items.first }
    }

    @State private var doubleTapID: UUID? = nil

    private func itemRow(_ element: ClipboardItem) -> some View {
        let sequenceIdx     = sequenceQueue.firstIndex(where: { $0.id == element.id })
        let alreadySelected = !showSequencePanel && selected?.id == element.id

        return ClipboardItemRow(
            element: element,
            isSelected: alreadySelected,
            sequenceIndex: showSequencePanel ? sequenceIdx.map { $0 + 1 } : nil,
            loadThumbnail: true,
            onTap: {
                if showSequencePanel {
                    if sequenceQueue.contains(where: { $0.id == element.id }) {
                        sequenceQueue.removeAll { $0.id == element.id }
                    } else {
                        sequenceQueue.append(element)
                    }
                } else {
                    // If the double-tap just flagged this item, paste only once
                    if doubleTapID == element.id {
                        doubleTapID = nil
                        monitor.paste(item: element); close()
                    } else if alreadySelected {
                        monitor.paste(item: element); close()
                    } else {
                        selected = element
                    }
                }
            },
            onDoubleTap: {
                guard !showSequencePanel else { return }
                // Flag the item so onTap (which fires right after) pastes only once
                doubleTapID = element.id
                selected    = element
            }
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            if text == L.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
            }
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func previewPanel(_ element: ClipboardItem) -> some View {
        // Layout: VStack in 3 blocks inside a 500 px tall container
        //
        // ┌─────────────────────────────────────────┐
        // │  BLOCK 1 : previewArea                   │  ← maxHeight: .infinity
        // │  (image / text / file)                   │
        // ├─────────────────────────────────────────┤
        // │  BLOCK 2 : infoRow                       │  ← natural fixed height
        // │  [app icon + name]  [dimensions]  [date] │
        // ├─────────────────────────────────────────┤
        // │  BLOCK 3 : buttonRow                     │  ← natural fixed height
        // │  [Paste] [Copy] [💾] [📌] [🗑]           │
        // └─────────────────────────────────────────┘

        let previewArea = ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.secondary.opacity(0.10))
            previewContent(for: element)
                .id(element.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: element.id)
        }

        let infoRow = HStack(alignment: .center) {
            HStack(spacing: 5) {
                Text(element.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(DateFormatter.fullDate.string(from: element.date))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }

        let buttonRow = HStack(spacing: 10) {
            AnimatedActionButton(title: L.pasteTitle, icon: "arrow.down.doc", helpText: L.pasteHint, fullWidth: true) {
                monitor.paste(item: element); close()
            }
            AnimatedActionButton(title: L.copyTitle, icon: "doc.on.doc", helpText: L.copyHint, fullWidth: true) {
                monitor.copyToClipboard(item: element)
            }
            if case .image(let img) = element.content { SaveImageButton(image: img) }
            if case .fileURL(let url) = element.content { SaveFileButton(url: url) }
            if case .text(let t) = element.content, (t.hasPrefix("http") || t.hasPrefix("www")), let url = URL(string: t) {
                HoverIconButton(symbol: "globe.americas.fill", color: .secondary, helpText: L.openInBrowser) {
                    NSWorkspace.shared.open(url)
                }
            }
            ItemPinButton(isPinned: element.isPinned) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    monitor.togglePin(item: element)
                    if selected?.id == element.id {
                        selected = monitor.items.first(where: { $0.id == element.id })
                    }
                }
            }
            HoverIconButton(symbol: "trash", color: .red, helpText: L.deleteItem) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    if selected?.id == element.id {
                        // Find the next item in the filtered list before deletion
                        let list = filteredItems
                        if let idx = list.firstIndex(where: { $0.id == element.id }) {
                            if idx + 1 < list.count {
                                selected = list[idx + 1]   // item just below
                            } else if idx > 0 {
                                selected = list[idx - 1]   // last of list → go up
                            } else {
                                selected = nil              // list empty after deletion
                            }
                        }
                    }
                    monitor.delete(item: element)
                }
            }
        }

        return VStack(spacing: 0) {
            previewArea
                .padding(.horizontal, 12)
                .padding(.top, 0)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            infoRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            buttonRow
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // OPTIMISATION 8: @ViewBuilder — SwiftUI sees the concrete type of each branch
    // and can diff efficiently without going through the AnyView black box.
    @ViewBuilder
    private func previewContent(for element: ClipboardItem) -> some View {
        switch element.content {
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .padding(16)
        case .text(let t):
            // OPTIMISATION 9: use cachedColor instead of re-running the regex
            if let color = element.cachedColor {
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(color)
                        .frame(width: 180, height: 180)
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    ColorSwatchView(color: color, label: t.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                ScrollView {
                    Text(t)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .fileURL(let url):
            FilePreview(url: url).padding(12)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard.fill").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(L.selectItem).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: activeFilter.icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(L.emptyFilter(filter: activeFilter.label)).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.top, 40).frame(maxWidth: .infinity)
    }
}

// MARK: - SDK Wrapper: protects dismiss() against premature closing
//
// Problem: DD Pro watches the mouse over its widget and calls dismiss()
// as soon as it leaves — even if it's heading toward our popup panel.
// When the mouse moves fast, the dismiss fires before the mouse has
// reached the panel, which then disappears immediately.
//
// Solution: makePanelBody (ClipboardPlugin) wraps the DD Pro dismiss
// in a guardedDismiss that waits 200 ms and checks via NSEvent.mouseLocation
// whether the mouse is inside the panel frame. If yes → close cancelled.
// Explicit closes (✕ button, shortcut) go through `close` directly.

// MARK: - Shared Plugin context ↔ Sentinel

/// Binding object transmitted by ClipboardPlugin to ClipboardPanelSDK
/// and then to NSPanelSentinel. The sentinel deposits the window reference
/// as soon as it is inserted in the hierarchy, allowing guardedDismiss to know
/// the panel frame in order to check the mouse position.
final class PanelWindowContext: @unchecked Sendable {
    weak var window: NSWindow?
    var pendingWorkItem: DispatchWorkItem?

    func cancelScheduledClose() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }
}

struct ClipboardPanelSDK: View {
    let monitor: ClipboardMonitor
    /// Explicit close (✕ button, shortcut) — always honored.
    let dismiss: () -> Void
    /// Delayed close with grace period — called by DD Pro when the mouse leaves the widget.
    let guardedDismiss: () -> Void
    let context: PanelWindowContext

    var body: some View {
        ClipboardPanel(
            monitor: monitor,
            close: dismiss
        )
        .background(NSPanelSentinel(context: context))
        .onHover { inside in
            // As soon as the mouse enters the panel, cancel the scheduled close.
            if inside { context.cancelScheduledClose() }
        }
    }
}

// MARK: - NSPanel Sentinel

/// Invisible NSView whose sole purpose is to deposit the NSWindow reference
/// into PanelWindowContext as soon as it is known.
private struct NSPanelSentinel: NSViewRepresentable {
    let context: PanelWindowContext

    func makeNSView(context ctx: Context) -> SentinelView {
        let view = SentinelView(context: context)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ view: SentinelView, context ctx: Context) {}

    // NSView subclass: viewDidMoveToWindow is reliable from insertion onwards.
    class SentinelView: NSView {
        let context: PanelWindowContext
        init(context: PanelWindowContext) {
            self.context = context
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            context.window = window
        }
    }
}
