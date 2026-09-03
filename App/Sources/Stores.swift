import Foundation
import SwiftUI

/// High-frequency telemetry lives OUTSIDE AppState on purpose: only the views
/// that actually draw it observe these stores, so a 10 Hz level update or a
/// caption token doesn't re-render the whole window (sidebar, scenes, menu
/// bar) the way an AppState @Published would.

@MainActor
final class LevelStore: ObservableObject {
    @Published var micDb: Float = -80
    @Published var micStreaming = false
    @Published var meetingDb: Float = -80
    @Published var meetingStreaming = false
}

@MainActor
final class CaptionStore: ObservableObject {
    @Published var captions: [Caption] = []
}
