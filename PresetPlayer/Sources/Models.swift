import AVFoundation

enum FilterType: String, Codable, CaseIterable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch

    var au: AVAudioUnitEQFilterType {
        switch self {
        case .peak: return .parametric
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .lowPass: return .lowPass
        case .highPass: return .highPass
        case .notch: return .bandStop
        }
    }
    var label: String {
        switch self {
        case .peak: return "Bell"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        }
    }
}

struct Band: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: FilterType = .peak
    var freq: Float = 1000
    var gain: Float = 0
    var q: Float = 1.0
    var enabled = true
}

struct Preset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var preamp: Float = 0
    var bands: [Band]
}

struct Track: Identifiable, Hashable {
    let id: String          // file path
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double = 0
}
