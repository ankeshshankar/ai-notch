import AVFoundation
import Foundation
import Speech
import os

/// Audio on its way to the analyzer: buffers in the microphone's (or a file's) format are turned
/// into the analyzer's format and yielded; until the analyzer is ready they wait here. The same
/// pump serves the microphone and the test file, so a file run exercises the real path.
final class AudioPump: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var finished = false
    /// The loudest sample level of the latest buffer, 0…1, for the waveform.
    var onLevel: (@Sendable (Float) -> Void)?
    private(set) var frames = 0

    /// Called from the audio thread (microphone) or any queue (file).
    func feed(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.level(of: buffer))
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let converter, let target, let sink else {
            if let copy = Self.copy(buffer) { pending.append(copy) }
            return
        }
        convert(buffer, with: converter, to: target, into: sink)
    }

    /// The analyzer is ready: drains what waited, then converts live.
    func attach(target: AVAudioFormat, source: AVAudioFormat, sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let converter = AVAudioConverter(from: source, to: target)
        if CommandLine.arguments.contains("--dictation-trace") { FileHandle.standardError.write(Data("pump \(source) -> \(target); converter \(converter == nil ? "nil" : "ok")\n".utf8)) }
        self.converter = converter
        self.target = target
        self.sink = sink
        guard let converter else { return }
        for buffer in pending { convert(buffer, with: converter, to: target, into: sink) }
        pending.removeAll()
    }

    func finish() {
        lock.lock()
        finished = true
        pending.removeAll()
        lock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat, into sink: (AVAudioPCMBuffer) -> Void) {
        if buffer.format == target { frames += Int(buffer.frameLength); sink(buffer); return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if CommandLine.arguments.contains("--dictation-trace") { FileHandle.standardError.write(Data("convert status \(status.rawValue) out \(out.frameLength) err \(String(describing: error))\n".utf8)) }
        if status != .error, out.frameLength > 0 { frames += Int(out.frameLength); sink(out) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        } else { return nil }
        return copy
    }

    /// RMS mapped from about -50 dB…0 dB onto 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(data[i]) / 32768; sum += v * v }
        } else { return 0 }
        let rms = (sum / Float(n)).squareRoot()
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }
}

enum DictationError: Error, Equatable {
    case unsupportedLocale(String)
    case modelNotReady
    case modelDownloading
    case downloadFailed
    case noAudioFormat
    case engine(String)
    case needsMacOS26

    var short: String {
        switch self {
        case .unsupportedLocale: return "Language not supported"
        case .modelNotReady: return "Language model not ready"
        case .modelDownloading: return "Model downloading"
        case .downloadFailed: return "Download failed"
        case .noAudioFormat: return "No audio format"
        case .engine: return "Mic error"
        case .needsMacOS26: return "Needs macOS 26"
        }
    }
}

/// Which on-device recogniser runs. Dictation honours custom vocabulary; the speech one does not.
enum SpeechEngine: String, Sendable { case dictation, speech }

/// One dictation's speech-to-text on macOS 26's on-device SpeechAnalyzer. Uses `DictationTranscriber`
/// (it takes contextual vocabulary) and falls back to `SpeechTranscriber` when the dictation
/// engine lacks the language or its assets.
@available(macOS 26.0, *)
final class SpeechDictation: @unchecked Sendable {
    let pump: AudioPump
    let engine: SpeechEngine
    private let analyzer: SpeechAnalyzer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Error>?
    private var started = false

    private init(engine: SpeechEngine, module: any SpeechModule, pump: AudioPump) {
        self.pump = pump
        self.engine = engine
        analyzer = SpeechAnalyzer(modules: [module])
    }

    private static func module(_ engine: SpeechEngine, _ locale: Locale, live: Bool = false) -> any SpeechModule {
        switch engine {
        case .dictation:
            return DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: live ? [.volatileResults] : [], attributeOptions: [])
        case .speech:
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: live ? [.volatileResults] : [], attributeOptions: [])
        }
    }

    /// The supported spelling of `identifier` for an engine, or nil.
    static func supportedLocale(_ identifier: String, engine: SpeechEngine) async -> Locale? {
        let wanted = Locale(identifier: identifier)
        switch engine {
        case .dictation: return await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        case .speech: return await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        }
    }

    /// The engine that serves `identifier` and its locale: dictation first, speech as the fallback.
    static func resolve(_ identifier: String, prefer: SpeechEngine? = nil) async -> (engine: SpeechEngine, locale: Locale)? {
        let order: [SpeechEngine] = prefer.map { [$0] } ?? [.dictation, .speech]
        for engine in order {
            if let locale = await supportedLocale(identifier, engine: engine) { return (engine, locale) }
        }
        return nil
    }

    /// The installed languages and the ones the engine supports, as locale identifiers.
    static func installed() async -> Set<String> {
        Set(await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            .union(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    }
    static func supported() async -> [Locale] {
        let dictation = await DictationTranscriber.supportedLocales
        return dictation.isEmpty ? await SpeechTranscriber.supportedLocales : dictation
    }

    /// Whether `locale`'s on-device model is installed (for the dictation engine).
    static func isInstalled(_ locale: Locale, engine: SpeechEngine = .dictation) async -> Bool {
        let installed: [Locale] = engine == .dictation ? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    /// Downloads a language's model when it is not installed, for the dictation engine and, failing
    /// that, the speech one. Returns the engine that is ready. `progress` is told 0…1.
    @discardableResult
    static func ensureAssets(for locale: Locale, prefer: SpeechEngine? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> SpeechEngine {
        var lastError: Error = DictationError.unsupportedLocale(locale.identifier)
        for engine in prefer.map({ [$0] }) ?? [.dictation, .speech] {
            guard let mine = await supportedLocale(locale.identifier(.bcp47), engine: engine) else { continue }
            do {
                try await ensureAssets(engine: engine, locale: mine, progress: progress)
                return engine
            } catch {
                DictationLog.log.error("\(engine.rawValue, privacy: .public) assets unavailable for \(locale.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func ensureAssets(engine: SpeechEngine, locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws {
        let module = Self.module(engine, locale)
        var status = await AssetInventory.status(forModules: [module])
        DictationLog.log.info("\(engine.rawValue, privacy: .public) asset status \(String(describing: status), privacy: .public) for \(locale.identifier, privacy: .public)")
        if CommandLine.arguments.contains("--dictation-trace") { FileHandle.standardError.write(Data("asset status \(status) for \(locale.identifier) (\(engine.rawValue))\n".utf8)) }
        if status == .installed { return }
        // A model another app (or an earlier run) installed still shows "supported" until this app
        // reserves the language; reserving is what makes it usable here, and needs no download.
        do {
            let reserved = try await AssetInventory.reserve(locale: locale)
            status = await AssetInventory.status(forModules: [module])
            DictationLog.log.info("reserved \(locale.identifier, privacy: .public): \(reserved, privacy: .public); status now \(String(describing: status), privacy: .public)")
        } catch {
            DictationLog.log.error("reserve failed for \(locale.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        if status == .installed { return }
        let request: AssetInstallationRequest?
        do { request = try await AssetInventory.assetInstallationRequest(supporting: [module]) } catch {
            DictationLog.log.error("install request failed: \(String(describing: error), privacy: .public)")
            throw DictationError.downloadFailed
        }
        guard let request else {
            // No request: either it is installed after all, or another download is running (wait for it).
            for _ in 0..<240 {
                status = await AssetInventory.status(forModules: [module])
                if status == .installed { return }
                if status != .downloading { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            DictationLog.log.error("no install request for \(locale.identifier, privacy: .public), status \(String(describing: status), privacy: .public)")
            throw status == .downloading ? DictationError.modelDownloading : DictationError.modelNotReady
        }
        if let progress {
            let watcher = Task { @Sendable in
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await download(request)
        } else {
            try await download(request)
        }
    }

    private static func download(_ request: AssetInstallationRequest) async throws {
        do { try await request.downloadAndInstall() } catch {
            DictationLog.log.error("download failed: \(String(describing: error), privacy: .public)")
            throw DictationError.downloadFailed
        }
    }

    /// Makes the analyzer for `locale`: finds the supported spelling, installs the model when
    /// missing, hands the engine its vocabulary, and starts it listening on a stream the pump feeds.
    /// `source` is the format of the audio the pump will be given. `prefer` names the first engine to try; without `fallback` it is the only one (tests).
    /// `onUpdate` hears the text settled so far and the volatile tail still changing, on every
    /// result; `onPhrase` hears each phrase the moment Apple marks it final. Both run off the main thread.
    static func start(localeIdentifier: String, source: AVAudioFormat, pump: AudioPump,
                      vocabulary: [String] = [], prefer: SpeechEngine? = nil, fallback: Bool = true,
                      progress: (@Sendable (Double) -> Void)? = nil,
                      onUpdate: (@Sendable (_ final: String, _ volatile: String) -> Void)? = nil,
                      onPhrase: (@Sendable (String) -> Void)? = nil) async throws -> SpeechDictation {
        let order: [SpeechEngine] = prefer.map { fallback ? [$0, $0 == .dictation ? .speech : .dictation] : [$0] } ?? [.dictation, .speech]
        var chosen: (engine: SpeechEngine, locale: Locale)?
        var lastError: Error = DictationError.unsupportedLocale(localeIdentifier)
        for engine in order {
            guard let locale = await supportedLocale(localeIdentifier, engine: engine) else { continue }
            do {
                try await ensureAssets(engine: engine, locale: locale, progress: progress)
                chosen = (engine, locale)
                break
            } catch {
                DictationLog.log.error("\(engine.rawValue, privacy: .public) unavailable for \(localeIdentifier, privacy: .public): \(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        guard let (engine, locale) = chosen else { throw lastError }
        let module = Self.module(engine, locale, live: true)
        let session = SpeechDictation(engine: engine, module: module, pump: pump)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source) else {
            DictationLog.log.error("no audio format for \(locale.identifier, privacy: .public) from \(source.sampleRate, privacy: .public) Hz \(source.channelCount, privacy: .public) ch")
            throw DictationError.noAudioFormat
        }
        DictationLog.log.info("\(engine.rawValue, privacy: .public) analyzer format \(format.sampleRate, privacy: .public) Hz \(format.channelCount, privacy: .public) ch, \(vocabulary.count, privacy: .public) terms")
        try await session.analyzer.prepareToAnalyze(in: format)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            do { try await session.analyzer.setContext(context) } catch {
                DictationLog.log.error("vocabulary not applied: \(String(describing: error), privacy: .public)")
            }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        session.continuation = continuation
        let trace = CommandLine.arguments.contains("--dictation-trace")
        func consume<S: AsyncSequence>(_ sequence: S, _ read: @escaping @Sendable (S.Element) -> (String, Bool)) -> Task<String, Error> where S: Sendable, S.Element: Sendable {
            Task {
                var text = ""
                var partials = 0
                let began = Date()
                for try await result in sequence {
                    let (raw, isFinal) = read(result)
                    let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isFinal {
                        if !piece.isEmpty { text += (text.isEmpty ? "" : " ") + piece; onPhrase?(piece) }
                        onUpdate?(text, "")
                    } else {
                        onUpdate?(text, piece)
                    }
                    if trace {
                        // Sizes only, never the words.
                        if !isFinal { partials += 1 }
                        FileHandle.standardError.write(Data(String(format: "t=%.2fs %@ result: %d chars; settled %d chars (partials so far %d)\n", Date().timeIntervalSince(began), isFinal ? "FINAL  " : "partial", piece.count, text.count, partials).utf8))
                    }
                }
                return text
            }
        }
        if let module = module as? DictationTranscriber {
            session.results = consume(module.results) { (String($0.text.characters), $0.isFinal) }
        } else if let module = module as? SpeechTranscriber {
            session.results = consume(module.results) { (String($0.text.characters), $0.isFinal) }
        }
        try await session.analyzer.start(inputSequence: stream)
        session.started = true
        session.pump.attach(target: format, source: source) { buffer in continuation.yield(AnalyzerInput(buffer: buffer)) }
        return session
    }

    /// Ends the input, lets the analyzer finish what it heard and returns the text.
    func finish() async throws -> String {
        pump.finish()
        continuation?.finish()
        if started { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        return try await results?.value ?? ""
    }

    func cancel() async {
        pump.finish()
        continuation?.finish()
        results?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// The microphone, through AVAudioEngine into an `AudioPump`.
final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    let pump: AudioPump
    let format: AVAudioFormat

    init(pump: AudioPump) throws {
        self.pump = pump
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.engine("no input device") }
        self.format = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [pump] buffer, _ in pump.feed(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw DictationError.engine("\(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
