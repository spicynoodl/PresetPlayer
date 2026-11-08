import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var lib = Library()
    @StateObject private var player = AudioPlayer()

    var body: some View {
        TabView {
            LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }
            NowPlayingView().tabItem { Label("Playing", systemImage: "play.circle") }
            EQView().tabItem { Label("EQ", systemImage: "slider.vertical.3") }
        }
        .environmentObject(lib)
        .environmentObject(player)
        .onAppear { lib.rescan() }
        .alert("PresetPlayer",
               isPresented: Binding(get: { player.message != nil },
                                    set: { if !$0 { player.message = nil } })) {
            Button("OK") {}
        } message: { Text(player.message ?? "") }
    }
}

func formatTime(_ s: Double) -> String {
    let n = Int(s.isFinite ? s : 0)
    return String(format: "%d:%02d", n / 60, n % 60)
}

// MARK: Library
struct LibraryView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: AudioPlayer
    @State private var search = ""
    @State private var showImporter = false

    var filtered: [Track] {
        search.isEmpty ? lib.tracks
            : lib.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if lib.isImporting { Text("Importing…").foregroundStyle(.secondary) }
                if lib.tracks.isEmpty && !lib.isImporting {
                    Text("No music yet. Tap + to add files or a whole folder.").foregroundStyle(.secondary)
                }
                ForEach(filtered) { t in
                    Button {
                        let list = filtered
                        player.play(list, startAt: list.firstIndex(where: { $0.id == t.id }) ?? 0)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title)
                                .foregroundStyle(player.current?.id == t.id ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                            Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add files or folder…") { showImporter = true }
                        Button("Rescan") { lib.rescan() }
                    } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
                        .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): lib.importItems(urls)
                case .failure(let e): lib.report = "Picker error: \(e.localizedDescription)"
                }
            }
            .alert("Import",
                   isPresented: Binding(get: { lib.report != nil },
                                        set: { if !$0 { lib.report = nil } })) {
                Button("OK") {}
            } message: { Text(lib.report ?? "") }
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayer
    var body: some View {
        if let t = player.current {
            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text(t.title).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: Now playing
struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let t = player.current {
                Text(t.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(t.artist).foregroundStyle(.secondary)
                Text(t.album).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing playing").foregroundStyle(.secondary)
            }
            VStack {
                Slider(value: Binding(get: { scrubbing ? scrub : player.position },
                                      set: { scrub = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: scrub) }
                }
                HStack {
                    Text(formatTime(scrubbing ? scrub : player.position))
                    Spacer()
                    Text(formatTime(player.duration))
                }
                .font(.caption).monospacedDigit()
            }
            HStack(spacing: 44) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: EQ
struct EQView: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var showImporter = false
    @State private var showSave = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Equalizer on", isOn: $player.eqEnabled)
                }
                Section("Presets (active: \(player.activePreset))") {
                    Button("Import preset (.json / .txt)") { showImporter = true }
                    Button("Save current as…") { newName = ""; showSave = true }
                    Button("Reset to flat") { player.resetFlat() }
                    ForEach(player.presets) { p in
                        Button(p.name) { player.apply(p) }
                    }
                    .onDelete { player.deletePresets(at: $0) }
                }
                .buttonStyle(.borderless)
                Section("Preamp") {
                    HStack {
                        Slider(value: $player.preamp, in: -24...12)
                        Text(String(format: "%+.1f dB", player.preamp)).monospacedDigit()
                    }
                }
                Section("Bands") {
                    ForEach($player.bands) { $b in BandRow(band: $b) }
                        .onDelete { player.bands.remove(atOffsets: $0) }
                    if player.bands.count < AudioPlayer.maxBands {
                        Button("Add band") { player.bands.append(Band()) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Equalizer")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json, .plainText]) { result in
                if case .success(let url) = result { player.importPreset(url) }
            }
            .alert("Save preset", isPresented: $showSave) {
                TextField("Name", text: $newName)
                Button("Save") { player.saveCurrent(as: newName) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct BandRow: View {
    @Binding var band: Band

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(Int(band.freq)) Hz").bold()
                Text(band.type.label).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f dB", band.gain)).monospacedDigit()
                Toggle("", isOn: $band.enabled).labelsHidden()
            }
            Slider(value: $band.gain, in: -24...24)
            HStack {
                Text("Hz").font(.caption)
                Slider(value: Binding(get: { log10(band.freq) },
                                      set: { band.freq = pow(10, $0) }),
                       in: log10(Float(20))...log10(Float(20000)))
            }
            HStack {
                Text("Q").font(.caption)
                Slider(value: $band.q, in: 0.1...10)
                Text(String(format: "%.2f", band.q)).font(.caption).monospacedDigit()
            }
        }
    }
}
