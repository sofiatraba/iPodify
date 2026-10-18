import SwiftUI

/// iPod classic Now Playing: "3 of 12", artwork with a reflection, song info, and a progress bar
/// that turns into a volume bar while you turn the wheel (or a scrubber after a center press).
struct NowPlayingView: View {
    @ObservedObject var ipod: IPod
    @ObservedObject var player: Player

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if let position = player.queuePosition {
                    Text("\(position.index) of \(position.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 6)
                        .padding(.leading, 10)
                }

                HStack(alignment: .top, spacing: 12) {
                    Artwork(url: player.track?.artworkURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.track?.name ?? "Not Playing")
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(2)
                        Text(player.track?.artist ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(player.track?.album ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                            .lineLimit(1)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                Spacer(minLength: 0)

                bottomBar(at: context.date)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .foregroundStyle(.black)
        }
    }

    @ViewBuilder
    private func bottomBar(at date: Date) -> some View {
        if ipod.wheelMode == .volume, date < ipod.showVolumeUntil {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 10))
                Bar(fraction: Double(player.volume) / 100)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
            }
        } else {
            let elapsed = player.progress(at: date)
            let duration = player.track?.durationMs ?? 0
            VStack(spacing: 3) {
                Bar(fraction: duration > 0 ? Double(elapsed) / Double(duration) : 0,
                    showsKnob: ipod.wheelMode == .scrub)
                HStack {
                    Text(Self.time(elapsed))
                    Spacer()
                    Text("-" + Self.time(max(0, duration - elapsed)))
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
    }

    static func time(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Bar: View {
    let fraction: Double
    var showsKnob = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
                Rectangle()
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.72, blue: 0.98), Color(red: 0.15, green: 0.45, blue: 0.86)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w)
                if showsKnob {
                    Diamond().fill(.black).frame(width: 10, height: 12).offset(x: w - 5)
                }
            }
            .overlay(Rectangle().stroke(Color(white: 0.5), lineWidth: 0.5))
        }
        .frame(height: 9)
    }
}

private struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        }
    }
}

private struct Artwork: View {
    let url: URL?
    private let size: CGFloat = 104

    var body: some View {
        VStack(spacing: 1) {
            image
                .frame(width: size, height: size)
                .clipped()
            // The classic reflection under the cover.
            image
                .frame(width: size, height: size)
                .clipped()
                .scaleEffect(x: 1, y: -1)
                .frame(height: size * 0.22, alignment: .top)
                .clipped()
                .opacity(0.35)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    private var image: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.9)
                    Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(Color(white: 0.6))
                }
            }
        }
    }
}
