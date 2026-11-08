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
                    if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for case let f as URL in en where Library.audioExts.contains(f.pathExtension.lowercased()) {
                            let rel = f.path.replacingOccurrences(of: url.path + "/", with: "")
                            Library.copy(f, to: destRoot.appendingPathComponent(rel))
                        }
                    }
                } else if Library.audioExts.contains(url.pathExtension.lowercased()) {
                    Library.copy(url, to: Library.musicDir.appendingPathComponent(url.lastPathComponent))
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                self.rescan()
            }
        }
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
