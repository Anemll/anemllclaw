import Foundation
import Observation

/// A provider that captures microphone audio and streams speech-to-text
/// transcription into the chat composer input field.
///
/// Conform to this protocol in the app layer (where `Speech` and
/// `AVFoundation` are available) and inject an instance into
/// ``OpenClawChatView`` to enable the dictation button.
@MainActor
public protocol ChatDictationProvider: AnyObject, Observable {
    /// `true` while the microphone is actively capturing audio.
    var isListening: Bool { get }

    /// Begin dictation.
    ///
    /// - Parameter onTranscript: Called on the main actor with the
    ///   cumulative best transcription each time partial results arrive.
    func startDictation(onTranscript: @escaping @MainActor (String) -> Void) async

    /// Stop dictation and finalize the current transcription.
    func stopDictation()
}
