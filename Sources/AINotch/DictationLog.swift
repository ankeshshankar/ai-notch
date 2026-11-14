import os

/// Dictation's diagnostics: `log show --predicate 'subsystem == "info.ankeshshiv.notch"'`.
/// States and error kinds only; never a transcript, audio or the API key.
enum DictationLog {
    static let log = Logger(subsystem: "info.ankeshshiv.notch", category: "dictation")
}
