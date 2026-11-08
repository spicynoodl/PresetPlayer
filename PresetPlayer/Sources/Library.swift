import AVFoundation
import Foundation

final class Library: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var isImporting = false

    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "mp4", "alac"]

    static var musicDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func rescan() {
        let dir = Library.musicDir
        DispatchQueue.global(qos: .utility).async {
            var urls: [URL] = []
            if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
                for case let u as URL in en where Library.audioExts.contains(u.pathExtension.lowercased()) {
                    urls.append(u)
                }
            }
            urls.sort { $0.path < $1.path }
            let list = urls.map {
                Track(id: $0.path, url: $0, title: $0.deletingPathExtension().lastPathComponent,
                      artist: "", album: "")
            }
            DispatchQueue.main.async {
                var old: [String: Track] = [:]
                for t in self.tracks { old[t.id] = t }
                self.tracks = list.map { old[$0.id] ?? $0 }
                self.loadMetadata()
            }
        }
    }

    func importItems(_ urls: [URL]) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let destRoot = Library.musicDir.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) {
                        for case let f as URL in en {
                            if let v = try? f.resourceValues(forKeys: [.isDirectoryKey]), v.isDirectory == true { continue }
                            let n = Library.destName(for: f)
                            if n.isEmpty { continue }
                            let rel = f.path.replacingOccurrences(of: url.path + "/", with: "")
                            let relDir = (rel as NSString).deletingLastPathComponent
                            let dst = destRoot.appendingPathComponent(relDir).appendingPathComponent(n)
                            Library.copy(f, to: dst)
                        }
                    }
                } else {
                    let n = Library.destName(for: url)
                    if !n.isEmpty {
                        Library.copy(url, to: Library.musicDir.appendingPathComponent(n))
                    }
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                self.rescan()
            }
        }
    }

    // Returns the file name to save as, or "" if the file isn't audio.
    private static func destName(for src: URL) -> String {
        let name = src.lastPathComponent
        if audioExts.contains(src.pathExtension.lowercased()) { return name }
        if let ext = detectExtension(src) { return name + "." + ext }
        return ""
    }

    // Looks at the first bytes of the file to work out its format.
    private static func detectExtension(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 12), d.count >= 8 else { return nil }
        let b = [UInt8](d)
        let head = String(decoding: d.prefix(4), as: UTF8.self)
        if head == "fLaC" { return "flac" }
        if head == "RIFF" { return "wav" }
        if head == "FORM" { return "aiff" }
        if head.hasPrefix("ID3") { return "mp3" }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return "mp3" }
        if String(decoding: d[4..<8], as: UTF8.self) == "ftyp" { return "m4a" }
        return nil
    }

    private static func copy(_ src: URL, to dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
    }

    private func loadMetadata() {
        let todo = tracks.filter { $0.artist.isEmpty && $0.album.isEmpty }
        if todo.isEmpty { return }
        Task {
            for t in todo {
                let asset = AVURLAsset(url: t.url)
                var title: String?
                var artist: String?
                var album: String?
                if let items = try? await asset.load(.commonMetadata) {
                    for item in items {
                        guard let key = item.commonKey else { continue }
                        let val = try? await item.load(.stringValue)
                        if key == .commonKeyTitle { title = val }
                        else if key == .commonKeyArtist { artist = val }
                        else if key == .commonKeyAlbumName { album = val }
                    }
                }
                let dur = (try? await asset.load(.duration))?.seconds ?? 0
                await MainActor.run {
                    if let i = self.tracks.firstIndex(where: { $0.id == t.id }) {
                        if let title, !title.isEmpty { self.tracks[i].title = title }
                        self.tracks[i].artist = artist ?? "Unknown artist"
                        self.tracks[i].album = album ?? "Unknown album"
                        self.tracks[i].duration = dur.isFinite ? dur : 0
                    }
                }
            }
        }
    }
}
