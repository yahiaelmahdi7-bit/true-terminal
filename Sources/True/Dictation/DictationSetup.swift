import Foundation

/// Finds `whisper-cli`: the user-set path if it is executable, else the first executable candidate.
enum DictationEngine {
    static let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/local/bin/whisper-cli"]
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func resolve(userPath: String = "", candidates: [String] = candidates,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let u = (userPath as NSString).expandingTildeInPath
        if !userPath.isEmpty, isExecutable(u) { return u }
        return candidates.first(where: isExecutable)
    }

    static func brew(candidates: [String] = brewCandidates,
                     isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates.first(where: isExecutable)
    }
}

/// The two pinned Whisper models (sizes and SHA-256 from the Hugging Face LFS pointer files).
struct WhisperModel: Equatable, Sendable, Identifiable {
    let file: String
    let sha256: String
    let size: Int64
    let title: String
    let sizeLabel: String
    var id: String { file }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    static let best = WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin",
                                   sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                                   size: 574_041_195, title: "Best", sizeLabel: "574 MB")
    static let light = WhisperModel(file: "ggml-small-q5_1.bin",
                                    sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
                                    size: 190_085_487, title: "Light", sizeLabel: "190 MB")
    static let all = [best, light]

    static var recommended: WhisperModel {
        #if arch(arm64)
        best
        #else
        light
        #endif
    }
}

enum DictationModels {
    static var downloadDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/True/whisper", isDirectory: true)
    }
    static var searchDirs: [String] { [downloadDir.path, NSHomeDirectory() + "/.cache/whisper"] }

    /// A set, existing, non-empty `userPath` wins; else the first known model file found in `dirs` (known-file order, then dir order).
    static func resolve(userPath: String, dirs: [String] = searchDirs, files: [String] = WhisperModel.all.map(\.file)) -> String? {
        let u = (userPath as NSString).expandingTildeInPath
        if !userPath.isEmpty, DictationSettings.modelValid(u) { return u }
        for d in dirs { for f in files {
            let p = (d as NSString).appendingPathComponent(f)
            if DictationSettings.modelValid(p) { return p }
        } }
        return nil
    }
}
