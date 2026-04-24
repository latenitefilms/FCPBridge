import Foundation
import WhisperKit

// Usage:
//   whisper-transcriber <audio-file>   [--progress] [--model large-v3|large-v3-turbo]
//   whisper-transcriber --batch <json> [--progress] [--model large-v3|large-v3-turbo]
//
// Output contract matches parakeet-transcriber:
//   Single mode: JSON array of word dicts to stdout
//   Batch mode:  JSON array of {"file":path, "words":[...]} to stdout
//   Progress:    "PROGRESS:<fraction>:<message>" lines to stderr when --progress set
//
// Runs Whisper via CoreML on the Apple Neural Engine using WhisperKit. The
// CoreML encoder + decoder is downloaded from HuggingFace on first use into
// ~/Library/Application Support/SpliceKit/Models/whisper/.

let progressLock = NSLock()

func reportProgress(_ fraction: Double, _ message: String) {
    progressLock.lock()
    let line = "PROGRESS:\(fraction):\(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    progressLock.unlock()
}

func printError(_ message: String) {
    progressLock.lock()
    FileHandle.standardError.write("ERROR:\(message)\n".data(using: .utf8)!)
    progressLock.unlock()
}

struct BatchEntry { let file: String }

let args = CommandLine.arguments
guard args.count >= 2 else {
    printError("Usage: whisper-transcriber <audio-file> [--progress] [--model large-v3|large-v3-turbo]")
    printError("       whisper-transcriber --batch <manifest.json> [--progress] [--model large-v3|large-v3-turbo]")
    exit(1)
}

let showProgress = args.contains("--progress")
let batchMode = args.contains("--batch")

// Default to large-v3-turbo (much faster, nearly identical quality for captions).
// WhisperKit variant names match HuggingFace repo subdirs under argmaxinc/whisperkit-coreml.
// Turbo variant is "large-v3_turbo" (underscore), not "large-v3-turbo" (hyphen).
var modelVariant = "large-v3_turbo"
var prettyName = "Whisper large-v3-turbo"
var approxSizeMB = 950
if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
    let choice = args[idx + 1].lowercased()
    switch choice {
    case "large-v3-turbo", "large-v3_turbo", "turbo", "v3-turbo":
        modelVariant = "large-v3_turbo"; prettyName = "Whisper large-v3-turbo"; approxSizeMB = 950
    case "large-v3", "v3":
        modelVariant = "large-v3"; prettyName = "Whisper large-v3"; approxSizeMB = 1550
    default:
        printError("Unknown model '\(choice)' — using large-v3_turbo")
    }
}

var batchEntries: [BatchEntry] = []
if batchMode {
    guard let batchIdx = args.firstIndex(of: "--batch"), batchIdx + 1 < args.count else {
        printError("--batch requires a manifest JSON file path")
        exit(1)
    }
    let manifestPath = args[batchIdx + 1]
    guard let data = FileManager.default.contents(atPath: manifestPath),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        printError("Failed to read batch manifest: \(manifestPath)")
        exit(1)
    }
    for entry in arr {
        if let file = entry["file"] as? String { batchEntries.append(BatchEntry(file: file)) }
    }
    if batchEntries.isEmpty {
        printError("No files in batch manifest"); exit(1)
    }
} else {
    let audioPath = args[1]
    guard FileManager.default.fileExists(atPath: audioPath) else {
        printError("File not found: \(audioPath)"); exit(1)
    }
    batchEntries.append(BatchEntry(file: audioPath))
}

// Models live under ~/Library/Application Support/SpliceKit/Models/whisper/
let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("SpliceKit/Models/whisper", isDirectory: true)
try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

// WhisperKit cache layout under downloadBase:
//   <downloadBase>/models/<modelRepo>/openai_whisper-<variant>/{MelSpectrogram,AudioEncoder,TextDecoder}.mlmodelc
let modelRepo = "argmaxinc/whisperkit-coreml"
let variantFolder = "openai_whisper-\(modelVariant)"
let fullModelPath = modelsDir
    .appendingPathComponent("models")
    .appendingPathComponent(modelRepo)
    .appendingPathComponent(variantFolder)
// A fully-downloaded .mlmodelc always contains weights/weight.bin. Checking just the directory
// misses interrupted downloads, producing a "Could not open weight.bin" load failure later.
let requiredComponents = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
let isCached = requiredComponents.allSatisfy { component -> Bool in
    let mlmodelc = fullModelPath.appendingPathComponent(component)
    guard FileManager.default.fileExists(atPath: mlmodelc.path) else { return false }
    let weight = mlmodelc.appendingPathComponent("weights/weight.bin")
    return FileManager.default.fileExists(atPath: weight.path)
}

func floatValue(_ value: Any?) -> Float? {
    if let value = value as? Float { return value }
    if let value = value as? Double { return Float(value) }
    if let value = value as? NSNumber { return value.floatValue }
    if let value = value as? String { return Float(value) }
    return nil
}

func normalizedWordTimings(_ words: [[String: Any]], minimumDuration: Float = 1.0 / 30.0) -> [[String: Any]] {
    var normalized = words.sorted {
        (floatValue($0["startTime"]) ?? 0) < (floatValue($1["startTime"]) ?? 0)
    }

    var previousEnd: Float = 0
    for index in normalized.indices {
        var start = floatValue(normalized[index]["startTime"]) ?? previousEnd
        var end = floatValue(normalized[index]["endTime"]) ?? (start + minimumDuration)

        if !start.isFinite { start = previousEnd }
        if !end.isFinite { end = start + minimumDuration }
        if start < previousEnd { start = previousEnd }
        if end <= start { end = start + minimumDuration }

        normalized[index]["startTime"] = start
        normalized[index]["endTime"] = end
        previousEnd = end
    }

    return normalized
}

func extractWords(from transcription: [TranscriptionResult]) -> [[String: Any]] {
    var words: [[String: Any]] = []
    for result in transcription {
        for segment in result.segments {
            if let wt = segment.words, !wt.isEmpty {
                for w in wt {
                    let trimmed = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    words.append([
                        "word": trimmed,
                        "startTime": Float(w.start),
                        "endTime": Float(w.end),
                        "confidence": Float(w.probability),
                    ])
                }
            } else {
                // Fallback: emit the whole segment as one word if no per-word timing.
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    words.append([
                        "word": trimmed,
                        "startTime": Float(segment.start),
                        "endTime": Float(segment.end),
                        "confidence": Float(1.0),
                    ])
                }
            }
        }
    }
    return normalizedWordTimings(words)
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        if showProgress {
            if isCached {
                reportProgress(0.05, "Loading \(prettyName) model (cached)...")
            } else {
                reportProgress(0.03, "Downloading \(prettyName) CoreML model (~\(approxSizeMB) MB)... First run only.")
            }
        }

        let config = WhisperKitConfig(
            model: modelVariant,
            downloadBase: modelsDir,
            modelRepo: modelRepo,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: false
        )

        let whisper: WhisperKit
        do {
            whisper = try await WhisperKit(config)
        } catch {
            printError("Failed to initialize WhisperKit: \(error.localizedDescription)")
            throw error
        }

        if !isCached {
            do {
                let downloadedURL = try await WhisperKit.download(
                    variant: modelVariant,
                    downloadBase: modelsDir,
                    useBackgroundSession: false,
                    from: modelRepo,
                    progressCallback: { progress in
                        if showProgress {
                            let frac = 0.05 + 0.55 * progress.fractionCompleted
                            reportProgress(frac, "Downloading \(prettyName)... \(Int(progress.fractionCompleted * 100))%")
                        }
                    }
                )
                whisper.modelFolder = downloadedURL
            } catch {
                let msg = error.localizedDescription
                if msg.contains("rate") || msg.contains("429") || msg.contains("503") {
                    printError("Model download rate-limited by HuggingFace. Wait a few minutes and try again.")
                } else if msg.contains("network") || msg.contains("connect") || msg.contains("NSURL") {
                    printError("Network error downloading model. Check internet connection: \(msg)")
                } else if msg.contains("space") || msg.contains("disk") {
                    printError("Not enough disk space for \(prettyName) (~\(approxSizeMB) MB).")
                } else {
                    printError("Model download failed: \(msg)")
                }
                printError("TIP: Delete \(fullModelPath.path) and retry.")
                throw error
            }
        }

        // When model is cached, WhisperKit's init() didn't discover it (download: false).
        // Set modelFolder to the cached path so loadModels() can find it.
        if isCached && whisper.modelFolder == nil {
            whisper.modelFolder = fullModelPath
        }

        if showProgress { reportProgress(0.62, "Compiling CoreML models for your device...") }

        do {
            try await whisper.loadModels()
        } catch {
            printError("Failed to load \(prettyName): \(error.localizedDescription)")
            printError("TIP: Whisper CoreML requires Apple Silicon. Delete \(fullModelPath.path) and retry if models are corrupt.")
            throw error
        }

        if showProgress { reportProgress(0.68, "\(prettyName) ready") }

        let totalFiles = Double(batchEntries.count)
        var allResults: [[String: Any]] = []

        for (index, entry) in batchEntries.enumerated() {
            guard FileManager.default.fileExists(atPath: entry.file) else {
                printError("File not found: \(entry.file)")
                if batchMode {
                    allResults.append(["file": entry.file, "words": [] as [Any], "error": "File not found"])
                }
                continue
            }
            if showProgress {
                let pct = 0.68 + (0.30 * Double(index) / totalFiles)
                let name = (entry.file as NSString).lastPathComponent
                reportProgress(pct, "Transcribing \(index + 1)/\(Int(totalFiles)): \(name)...")
            }

            // Use .none rather than .vad: VAD was dropping long stretches of the source
            // (e.g. first 83s of a 4-min Tim Keller meditation, ~70% fewer words than
            // Parakeet). .none slides a 30s window across the whole file so nothing is
            // skipped. For a 4-min file this costs seconds of extra inference.
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,
                temperature: 0.0,
                wordTimestamps: true,
                chunkingStrategy: .none
            )

            do {
                let results = try await whisper.transcribe(audioPath: entry.file, decodeOptions: options)
                let words = extractWords(from: results)
                if batchMode {
                    allResults.append(["file": entry.file, "words": words])
                } else {
                    allResults = words
                }
            } catch {
                printError("Transcription failed for \(entry.file): \(error.localizedDescription)")
                if batchMode {
                    allResults.append(["file": entry.file, "words": [] as [Any], "error": error.localizedDescription])
                } else {
                    throw error
                }
            }
        }

        if showProgress {
            let totalWords = allResults.reduce(0) { sum, r in
                if let words = r["words"] as? [[String: Any]] { return sum + words.count }
                if r["word"] != nil { return sum + 1 }
                return sum
            }
            reportProgress(1.0, "Done — \(totalWords) words from \(batchEntries.count) file(s)")
        }

        let jsonData = try JSONSerialization.data(withJSONObject: allResults, options: [.sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) { print(jsonString) }

    } catch {
        let errMsg = error.localizedDescription
        printError("Whisper transcription failed: \(errMsg)")
        if errMsg.contains("memory") || errMsg.contains("Memory") {
            printError("TIP: Close other apps to free RAM — Whisper large-v3 needs ~3 GB available.")
        }
        if errMsg.contains("CoreML") || errMsg.contains("mlmodel") {
            printError("TIP: Delete \(fullModelPath.path) and re-run to redownload the model.")
        }
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
