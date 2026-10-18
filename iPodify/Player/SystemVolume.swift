import AVFoundation
import MediaPlayer
import SwiftUI

/// Spotify on iPhone doesn't accept volume changes over the Web API, so the wheel sets the
/// phone's own output volume instead. A hidden MPVolumeView also suppresses the system volume HUD.
@MainActor
final class SystemVolume {
    static let shared = SystemVolume()
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    var current: Float { AVAudioSession.sharedInstance().outputVolume }

    func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = max(0, min(1, value))
    }
}

/// Place once in the view hierarchy (invisible) so `SystemVolume` works.
struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = SystemVolume.shared.view
        view.alpha = 0.01
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
