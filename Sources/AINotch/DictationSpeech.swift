import AVFoundation
import Foundation
import Speech

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
    case assetsUnavailable
    case engine(String)
    case needsMacOS26

    var short: String {
        switch self {
        case .unsupportedLocale: return "Language not supported"
        case .assetsUnavailable: return "Language not installed"
        case .engine: return "Mic error"
        case .needsMacOS26: return "Needs macOS 26"
        }
    }
}

/// One dictation's speech-to-text on macOS 26's on-device SpeechAnalyzer.
@available(macOS 26.0, *)
final class SpeechDictation: @unchecked Sendable {
    let pump: AudioPump
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let localeIdentifier: String
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Error>?
    private var started = false

    private init(transcriber: SpeechTranscriber, locale: Locale, pump: AudioPump) {
        self.pump = pump
        self.transcriber = transcriber
        self.localeIdentifier = locale.identifier
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// The installed languages and the ones the engine supports, as locale identifiers.
    static func installed() async -> Set<String> { Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }) }
    static func supported() async -> [Locale] { await SpeechTranscriber.supportedLocales }

    /// Whether `locale`'s on-device model is installed.
    static func isInstalled(_ locale: Locale) async -> Bool {
        await installed().contains(locale.identifier(.bcp47))
    }

    /// Downloads a language's model when it is not installed. `progress` is told 0…1.
    static func ensureAssets(for locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        if CommandLine.arguments.contains("--dictation-trace") { FileHandle.standardError.write(Data("asset status \(status) for \(locale.identifier)\n".utf8)) }
        if status == .installed { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { throw DictationError.assetsUnavailable }
        if let progress {
            let watcher = Task { @Sendable in
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        } else {
            try await request.downloadAndInstall()
        }
    }

    /// Makes the analyzer for `locale`: finds the supported spelling, installs the model when
    /// missing, and starts it listening on a stream the pump feeds.
    /// `source` is the format of the audio the pump will be given.
    static func start(localeIdentifier: String, source: AVAudioFormat, pump: AudioPump,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> SpeechDictation {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw DictationError.unsupportedLocale(localeIdentifier)
        }
        try await ensureAssets(for: locale, progress: progress)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let session = SpeechDictation(transcriber: transcriber, locale: locale, pump: pump)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source) else {
            throw DictationError.assetsUnavailable
        }
        try await session.analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        session.continuation = continuation
        session.results = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { text += (text.isEmpty ? "" : " ") + piece }
            }
            return text
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
