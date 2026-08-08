import AVFAudio
import Foundation
import Speech

enum ComposerDictationSupport {
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func isSpeechAuthorizationFailure(_ error: Error) -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined || status == .denied || status == .restricted else {
            return false
        }
        return (error as NSError).domain == "SFSpeechErrorDomain"
    }

    static func notice(for error: Error) -> ComposerDictationNotice {
        switch error {
        case DictationError.microphoneDenied:
            ComposerDictationNotice(
                title: "Microphone Access Needed",
                message: "Allow microphone access in Settings to dictate messages.",
                offersSettings: true
            )
        case DictationError.speechDenied:
            ComposerDictationNotice(
                title: "Speech Recognition Access Needed",
                message: "Allow speech recognition in Settings to dictate messages.",
                offersSettings: true
            )
        case DictationError.unsupportedLocale:
            ComposerDictationNotice(
                title: "Language Not Available",
                message: "On-device dictation is not available for the current language.",
                offersSettings: false
            )
        case DictationError.localeCapacity:
            ComposerDictationNotice(
                title: "Dictation Models Full",
                message: "This device has reached its limit for reserved dictation languages.",
                offersSettings: false
            )
        default:
            ComposerDictationNotice(
                title: "Dictation Could Not Start",
                message: error.localizedDescription,
                offersSettings: false
            )
        }
    }

    static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }

    static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

enum DictationError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case unavailable
    case unsupportedLocale
    case localeCapacity
    case assetInstallation
    case audioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access was denied."
        case .speechDenied: "Speech recognition access was denied."
        case .unavailable: "On-device speech recognition is unavailable on this device."
        case .unsupportedLocale: "The current language is not supported for dictation."
        case .localeCapacity: "The device cannot reserve another dictation language."
        case .assetInstallation: "The on-device dictation model could not be installed."
        case .audioFormat: "The microphone format is not supported for dictation."
        }
    }
}
