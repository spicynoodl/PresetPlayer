import AVFoundation
import MediaPlayer

final class AudioPlayer: ObservableObject {
    static let maxBands = 32
    static let flat10: [Band] = ([31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] as [Float])
        .map { Band(freq: $0, q: 1.41) }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioPlayer.maxBands)
    private var file: AVAudioFile?
    private var generation = 0
    private var seekOffset: Double = 0
    private var timer: Timer?

    @Published var queue: [Track] = []
    @Published var index: Int?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0

    @Published var bands: [Band] = AudioPlayer.flat10 { didSet { applyEQ() } }
    @Published var preamp: Float = 0 { didSet { applyEQ() } }
    @Published var eqEnabled = true { didSet { applyEQ() } }
    @Published var presets: [Preset] = []
    @Published var activePreset = "Flat"
    @Published var message: String?

    var current: Track? {
        guard let i = index, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private var presetsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("presets.json")
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(node)
        engine.attach(eq)
        if let d = try? Data(contentsOf: presetsURL),
           let p = try? JSONDecoder().decode([Preset].self, from: d) { presets = p }
        applyEQ()
        setupRemote()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] n in
            guard let self,
                  let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: v) else { return }
            if type == .began {
                self.isPlaying = false
            } else if let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume),
                      self.file != nil {
                try? self.engine.start()
                self.node.play()
                self.isPlaying = true
            }
        }
    }

    // MARK: EQ
    static func bandwidth(fromQ q: Float) -> Float {
        let q = max(q, 0.05)
        let bw = 2 * asinh(1 / (2 * q)) / Float(M_LN2)
        return min(5, max(0.05, bw))
    }

    private func applyEQ() {
        eq.bypass = !eqEnabled
        eq.globalGain = min(24, max(-96, preamp))
        for (i, b) in eq.bands.enumerated() {
            if i < bands.count {
                let s = bands[i]
                b.filterType = s.type.au
                b.frequency = min(20000, max(20, s.freq))
                b.gain = min(24, max(-96, s.gain))
                b.bandwidth = Self.bandwidth(fromQ: s.q)
                b.bypass = !s.enabled
            } else {
                b.bypass = true
            }
        }
    }

    // MARK: Playback
    func play(_ tracks: [Track], startAt i: Int) {
        queue = tracks
        load(index: i, autoplay: true)
    }

    private func load(index i: Int, autoplay: Bool) {
        guard queue.indices.contains(i) else { return }
        let t = queue[i]
        do {
            let f = try AVAudioFile(forReading: t.url)
            generation += 1
            node.stop()
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: eq, format: f.processingFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: f.processingFormat)
            file = f
            index = i
            duration = Double(f.length) / f.processingFormat.sampleRate
            seekOffset = 0
            position = 0
            applyEQ()
            try engine.start()
            schedule(from: 0)
            if autoplay { node.play() }
            isPlaying = autoplay
            startTimer()
            updateNowPlaying()
        } catch {
            message = "Could not play \(t.title): \(error.localizedDescription)"
        }
    }

    private func schedule(from seconds: Double) {
        guard let f = file, f.length > 1 else { return }
        let sr = f.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, min(seconds * sr, Double(f.length - 1))))
        let count = AVAudioFrameCount(f.length - start)
        generation += 1
        let g = generation
        node.scheduleSegment(f, startingFrame: start, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                self.next()
            }
        }
    }

    func togglePlay() {
        guard file != nil else { return }
        if isPlaying {
            node.pause()
            isPlaying = false
        } else {
            if !engine.isRunning { try? engine.start() }
            node.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func next() {
        guard let i = index else { return }
        if i + 1 < queue.count {
            load(index: i + 1, autoplay: true)
        } else {
            generation += 1
            node.stop()
            isPlaying = false
            seekOffset = 0
            position = 0
            schedule(from: 0)
            updateNowPlaying()
        }
    }

    func previous() {
        guard let i = index else { return }
        if position > 3 || i == 0 { seek(to: 0) } else { load(index: i - 1, autoplay: true) }
    }

    func seek(to s: Double) {
        guard file != nil else { return }
        let was = isPlaying
        generation += 1
        node.stop()
        seekOffset = max(0, min(s, duration))
        position = seekOffset
        schedule(from: seekOffset)
        if was { node.play() }
        updateNowPlaying()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying,
                  let t = self.node.lastRenderTime,
                  let pt = self.node.playerTime(forNodeTime: t) else { return }
            self.position = min(self.duration, self.seekOffset + Double(pt.sampleTime) / pt.sampleRate)
        }
    }

    // MARK: Lock screen / control center
    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { if let s = self, !s.isPlaying { s.togglePlay() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { if let s = self, s.isPlaying { s.togglePlay() } }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent {
                DispatchQueue.main.async { self?.seek(to: e.positionTime) }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    // MARK: Presets
    func apply(_ p: Preset) {
        bands = Array(p.bands.prefix(Self.maxBands))
        preamp = p.preamp
        activePreset = p.name
    }

    func resetFlat() {
        bands = Self.flat10
        preamp = 0
        activePreset = "Flat"
    }

    func saveCurrent(as name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store(Preset(name: n, preamp: preamp, bands: bands))
        activePreset = n
    }

    private func store(_ p: Preset) {
        if let i = presets.firstIndex(where: { $0.name == p.name }) { presets[i] = p } else { presets.append(p) }
        persist()
    }

    func deletePresets(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(presets) { try? d.write(to: presetsURL) }
    }

    func importPreset(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "Could not read preset file."; return }
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        let p = ext == "json"
            ? PresetParser.easyEffects(data, name: name)
            : PresetParser.autoEQ(String(decoding: data, as: UTF8.self), name: name)
        if let p { store(p); apply(p) } else { message = "No equalizer bands found in that file." }
    }
}
