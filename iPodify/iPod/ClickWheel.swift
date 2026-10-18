import SwiftUI

/// Drag around the ring to scroll; tap the ring's edges for MENU / ⏮ / ⏭ / ⏯; tap the center to select.
struct ClickWheel: View {
    let theme: Theme
    let onStep: (Int) -> Void
    let onMenu: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPlayPause: () -> Void
    let onSelect: () -> Void

    /// Steps per full turn. The real wheel felt like ~20.
    private let stepsPerTurn = 20.0

    @State private var lastAngle: Double?
    @State private var accumulated = 0.0
    @State private var travelled = 0.0
    @State private var centerPressed = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle()
                    .fill(wheelFill)
                    .overlay(Circle().stroke(wheelStroke, lineWidth: 1))
                    .shadow(color: .black.opacity(theme == .silver ? 0.08 : 0.4), radius: 2, y: 1)

                labels(size: size)

                Circle()
                    .fill(centerFill)
                    .overlay(Circle().stroke(wheelStroke, lineWidth: 1))
                    .frame(width: size * 0.38, height: size * 0.38)
                    .brightness(centerPressed ? -0.06 : 0)
            }
            .frame(width: size, height: size)
            .position(center)
            .contentShape(Circle())
            .gesture(ringGesture(center: center, size: size))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func labels(size: CGFloat) -> some View {
        let inset = size * 0.13
        return ZStack {
            Text("MENU").font(.system(size: size * 0.058, weight: .bold))
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, inset - size * 0.03)
            Image(systemName: "backward.end.alt.fill").font(.system(size: size * 0.05))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset - size * 0.04)
            Image(systemName: "forward.end.alt.fill").font(.system(size: size * 0.05))
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, inset - size * 0.04)
            Image(systemName: "playpause.fill").font(.system(size: size * 0.05))
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, inset - size * 0.03)
        }
        .foregroundStyle(theme == .silver ? Color(white: 0.68) : Color(white: 0.82))
        .allowsHitTesting(false)
    }

    private func ringGesture(center: CGPoint, size: CGFloat) -> some Gesture {
        // One gesture for the whole wheel, so a press in the middle can't be mistaken for the ring.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fromCenter = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
                if fromCenter < size * 0.19 {
                    centerPressed = true
                    return
                }
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                defer { lastAngle = angle }
                guard let last = lastAngle else { return }
                var delta = angle - last
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                accumulated += delta
                travelled += abs(delta)

                let step = 2 * .pi / stepsPerTurn
                while accumulated >= step { accumulated -= step; onStep(1) }
                while accumulated <= -step { accumulated += step; onStep(-1) }
            }
            .onEnded { value in
                defer { lastAngle = nil; accumulated = 0; travelled = 0 }
                if centerPressed {
                    centerPressed = false
                    onSelect()
                    return
                }
                // Barely moved: it's a press on one of the four buttons.
                let moved = hypot(value.translation.width, value.translation.height)
                guard travelled < 0.15, moved < 12 else { return }
                let degrees = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                switch degrees {
                case -135 ..< -45: onMenu()
                case -45 ..< 45: onNext()
                case 45 ..< 135: onPlayPause()
                default: onPrevious()
                }
            }
    }

    private var wheelFill: some ShapeStyle {
        theme == .silver
            ? LinearGradient(colors: [Color(white: 0.97), Color(white: 0.92)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.20), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
    }

    private var centerFill: some ShapeStyle {
        theme == .silver
            ? LinearGradient(colors: [Color(white: 0.93), Color(white: 0.99)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.07), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
    }

    private var wheelStroke: Color {
        theme == .silver ? Color(white: 0.82) : Color(white: 0.05)
    }
}
