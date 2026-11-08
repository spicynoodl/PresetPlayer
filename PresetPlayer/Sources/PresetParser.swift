import Foundation

enum PresetParser {
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
        return String(s[rr])
    }

    // AutoEQ / Equalizer APO "ParametricEQ.txt"
    // Preamp: -6.2 dB
    // Filter 1: ON PK Fc 31 Hz Gain 1.2 dB Q 1.41
    static func autoEQ(_ text: String, name: String) -> Preset? {
        var preamp: Float = 0
        var bands: [Band] = []
        let pre = try! NSRegularExpression(pattern: #"Preamp:\s*(-?[\d.]+)\s*dB"#, options: .caseInsensitive)
        let flt = try! NSRegularExpression(
            pattern: #"Filter\s*\d*:\s*(ON|OFF)\s+(\w+)\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?"#,
            options: .caseInsensitive)
        for line in text.components(separatedBy: .newlines) {
            let r = NSRange(line.startIndex..., in: line)
            if let m = pre.firstMatch(in: line, range: r) {
                preamp = Float(group(m, 1, line) ?? "") ?? 0
            } else if let m = flt.firstMatch(in: line, range: r) {
                let on = (group(m, 1, line) ?? "ON").uppercased() == "ON"
                let t = (group(m, 2, line) ?? "PK").uppercased()
                let type: FilterType
                switch t {
                case "LS", "LSC": type = .lowShelf
                case "HS", "HSC": type = .highShelf
                case "LP", "LPQ": type = .lowPass
                case "HP", "HPQ": type = .highPass
                case "NO": type = .notch
                default: type = .peak
                }
                let defaultQ: Float = (type == .peak || type == .notch) ? 1.0 : 0.707
                bands.append(Band(type: type,
                                  freq: Float(group(m, 3, line) ?? "") ?? 1000,
                                  gain: Float(group(m, 4, line) ?? "") ?? 0,
                                  q: Float(group(m, 5, line) ?? "") ?? defaultQ,
                                  enabled: on))
            }
        }
        return bands.isEmpty ? nil : Preset(name: name, preamp: preamp, bands: bands)
    }

    // EasyEffects preset JSON (output.equalizer / equalizer#0)
    static func easyEffects(_ data: Data, name: String) -> Preset? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func findEQ(_ d: [String: Any]) -> [String: Any]? {
            for (k, v) in d where k.hasPrefix("equalizer") {
                if let e = v as? [String: Any] { return e }
            }
            for (_, v) in d {
                if let sub = v as? [String: Any], let f = findEQ(sub) { return f }
            }
            return nil
        }
        let eq: [String: Any]?
        if let out = root["output"] as? [String: Any], let f = findEQ(out) { eq = f }
        else { eq = findEQ(root) }
        guard let eq else { return nil }

        let preamp = (eq["input-gain"] as? NSNumber)?.floatValue ?? 0
        let channel = (eq["left"] as? [String: Any]) ?? eq
        let keys = channel.keys.filter { $0.hasPrefix("band") }
            .sorted { (Int($0.dropFirst(4)) ?? 0) < (Int($1.dropFirst(4)) ?? 0) }

        var bands: [Band] = []
        for k in keys {
            guard let b = channel[k] as? [String: Any] else { continue }
            let t = (b["type"] as? String ?? "Bell").lowercased()
            let type: FilterType
            switch t {
            case "lo-shelf": type = .lowShelf
            case "hi-shelf": type = .highShelf
            case "lo-pass": type = .lowPass
            case "hi-pass": type = .highPass
            case "notch": type = .notch
            default: type = .peak
            }
            let muted = (b["mute"] as? Bool) ?? false
            bands.append(Band(type: type,
                              freq: (b["frequency"] as? NSNumber)?.floatValue ?? 1000,
                              gain: (b["gain"] as? NSNumber)?.floatValue ?? 0,
                              q: (b["q"] as? NSNumber)?.floatValue ?? 1.0,
                              enabled: !muted))
        }
        return bands.isEmpty ? nil : Preset(name: name, preamp: preamp, bands: bands)
    }
}
