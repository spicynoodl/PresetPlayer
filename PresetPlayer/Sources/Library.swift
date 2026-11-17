import AVFoundation
import Foundation

final class Library: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var isImporting = false
    @Published var report: String?

    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "mp4", "alac"]
    // Files with these extensions are never audio; skip them without copying (cover art, playlists, etc.)
    static let ignoredExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "txt", "m3u", "m3u8", "cue",
                                           "log", "pdf", "nfo", "db", "ini", "lrc", "json", "xml", "url", "sfv", "md5"]

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
                for case let u as URL in en where Library.audioExts.contains(u.pathExtension.lowercased())
                    && !u.lastPathComponent.hasPrefix("._") {
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

    private enum ImportResult {
        case copied
        case ignored
        case notAudio(String)
        case failed(String)
    }

    func importItems(_ urls: [URL]) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var copied = 0
            var skipped: [String] = []
            var failed: [String] = []

            func process(_ f: URL, destDir: URL) {
                let name = f.lastPathComponent
                if name.hasPrefix("._") { return }
                switch Library.importOne(f, destDir: destDir) {
                case .copied: copied += 1
                case .ignored: break
                case .notAudio(let d): skipped.append(d)
                case .failed(let e): failed.append("\(name): \(e)")
                }
            }

            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !exists {
                    failed.append("\(url.lastPathComponent): cannot be read")
                } else if isDir.boolValue {
                    let base = url.resolvingSymlinksInPath().path
                    let destRoot = Library.musicDir.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) {
                        for case let f as URL in en {
                            if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                            let fp = f.resolvingSymlinksInPath().path
                            let rel = fp.hasPrefix(base + "/") ? String(fp.dropFirst(base.count + 1)) : f.lastPathComponent
                            let relDir = (rel as NSString).deletingLastPathComponent
                            let dest = relDir.isEmpty ? destRoot : destRoot.appendingPathComponent(relDir, isDirectory: true)
                            process(f, destDir: dest)
                        }
                    }
                } else {
                    process(url, destDir: Library.musicDir)
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }

            var msg = "Imported \(copied) file(s)."
            if !skipped.isEmpty {
                msg += "\nSkipped \(skipped.count) (not recognised as audio): " + skipped.prefix(3).joined(separator: "; ")
            }
            if !failed.isEmpty {
                msg += "\nCopy failed for \(failed.count): " + failed.prefix(2).joined(separator: "; ")
            }
            DispatchQueue.main.async {
                self.isImporting = false
                self.report = msg
                self.rescan()
            }
        }
    }

    private static func importOne(_ src: URL, destDir: URL) -> ImportResult {
        let fm = FileManager.default
        let name = src.lastPathComponent
        let ext = src.pathExtension.lowercased()
        let known = audioExts.contains(ext)
        if !known && ignoredExts.contains(ext) { return .ignored }
        do { try fm.createDirectory(at: destDir, withIntermediateDirectories: true) }
        catch { return .failed(error.localizedDescription) }

        if known {
            let dst = destDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { return .copied }
            if let e = coordinatedCopy(src, to: dst) { return .failed(e) }
            return .copied
        }

        // Unknown or missing extension: copy to a temp file, look at the bytes, then name it properly.
        let tmp = destDir.appendingPathComponent(".import-" + UUID().uuidString)
        if let e = coordinatedCopy(src, to: tmp) { return .failed(e) }
        guard let detected = detectExtension(tmp) else {
            let d = describe(tmp, name: name)
            try? fm.removeItem(at: tmp)
            return .notAudio(d)
        }
        let final = destDir.appendingPathComponent(name + "." + detected)
        if fm.fileExists(atPath: final.path) {
            try? fm.removeItem(at: tmp)
        } else {
            do { try fm.moveItem(at: tmp, to: final) }
            catch {
                try? fm.removeItem(at: tmp)
                return .failed(error.localizedDescription)
            }
        }
        return .copied
    }

    // Looks at the first bytes of the file to work out its format.
    private static func detectExtension(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 12), d.count >= 10 else { return nil }
        let b = [UInt8](d)
        let head = String(decoding: d.prefix(4), as: UTF8.self)
        if head == "fLaC" { return "flac" }
        if head == "RIFF" { return "wav" }
        if head == "FORM" { return "aiff" }
        if head.hasPrefix("ID3") {
            // Skip the ID3 tag: FLAC files sometimes carry one.
            let size = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
            try? h.seek(toOffset: UInt64(10 + size))
            if let n = try? h.read(upToCount: 4), String(decoding: n, as: UTF8.self) == "fLaC" { return "flac" }
            return "mp3"
        }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return "mp3" }
        if String(decoding: d[4..<8], as: UTF8.self) == "ftyp" { return "m4a" }
        return nil
    }

    private static func describe(_ u: URL, name: String) -> String {
        var hex = "cannot read file"
        if let h = try? FileHandle(forReadingFrom: u) {
            if let d = try? h.read(upToCount: 8) {
                hex = d.map { String(format: "%02X", UInt32($0)) }.joined(separator: " ")
            }
            try? h.close()
        }
        return "\(name) [\(hex)]"
    }

    // Copies through NSFileCoordinator so files from VLC / iCloud / other providers are fully available first.
    private static func coordinatedCopy(_ src: URL, to dst: URL) -> String? {
        let fm = FileManager.default
        var coordError: NSError?
        var copyError: String?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
            do { try fm.copyItem(at: readURL, to: dst) }
            catch { copyError = error.localizedDescription }
        }
        if let e = coordError { return e.localizedDescription }
        return copyError
    }

    private struct Meta {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double
    }

    private static func readMetadata(_ url: URL) async -> Meta {
        let asset = AVURLAsset(url: url)
        var m = Meta(title: nil, artist: nil, album: nil, duration: 0)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let val = try? await item.load(.stringValue)
                if key == .commonKeyTitle { m.title = val }
                else if key == .commonKeyArtist { m.artist = val }
                else if key == .commonKeyAlbumName { m.album = val }
            }
        }
        if let dur = try? await asset.load(.duration), dur.seconds.isFinite { m.duration = dur.seconds }
        return m
    }

    private func loadMetadata() {
        let todo = tracks.filter { $0.artist.isEmpty && $0.album.isEmpty }
        if todo.isEmpty { return }
        Task {
            for t in todo {
                let meta = await Library.readMetadata(t.url)
                await MainActor.run {
                    if let i = self.tracks.firstIndex(where: { $0.id == t.id }) {
                        if let title = meta.title, !title.isEmpty { self.tracks[i].title = title }
                        self.tracks[i].artist = meta.artist ?? "Unknown artist"
                        self.tracks[i].album = meta.album ?? "Unknown album"
                        self.tracks[i].duration = meta.duration
                    }
                }
            }
        }
    }
}
