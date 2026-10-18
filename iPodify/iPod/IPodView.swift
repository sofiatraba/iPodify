import SwiftUI

/// The whole phone becomes the iPod: screen on top, click wheel below.
struct IPodView: View {
    @ObservedObject var ipod: IPod
    @ObservedObject var library: Library
    @ObservedObject var player: Player

    var body: some View {
        GeometryReader { outer in
            // Some phones put the camera in a corner and report it as a side inset: centre the iPod
            // anyway, but drop the screen below the camera.
            let cutout = max(outer.safeAreaInsets.leading, outer.safeAreaInsets.trailing)
            GeometryReader { geo in
                let gutter: CGFloat = 22
                let screenWidth = geo.size.width - gutter * 2
                let screenHeight = min(screenWidth * 0.78, geo.size.height * 0.45)

                VStack(spacing: 0) {
                    ScreenView(ipod: ipod, library: library, player: player)
                        .frame(width: screenWidth, height: screenHeight)
                        .padding(.top, gutter + cutout)

                    Spacer(minLength: 16)

                    ClickWheel(
                        theme: ipod.theme,
                        onStep: ipod.wheel,
                        onMenu: ipod.menu,
                        onPrevious: ipod.previous,
                        onNext: ipod.next,
                        onPlayPause: ipod.playPause,
                        onSelect: ipod.select
                    )
                    .frame(width: min(screenWidth * 0.86, geo.size.height - screenHeight - cutout - gutter - 40))

                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
        }
        .background(casing(for: ipod.theme).ignoresSafeArea())
        .background(SystemVolumeHost().frame(width: 1, height: 1))
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func casing(for theme: Theme) -> LinearGradient {
        theme == .silver
            ? LinearGradient(colors: [Color(white: 0.985), Color(white: 0.90)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
    }
}
