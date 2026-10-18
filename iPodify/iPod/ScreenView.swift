import SwiftUI

/// The little LCD: a title bar, then either a menu or Now Playing.
struct ScreenView: View {
    @ObservedObject var ipod: IPod
    @ObservedObject var library: Library
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: ipod.title(for: ipod.current.screen), isPlaying: player.isPlaying)
            ZStack {
                if library.isSyncing && (library.snapshot.syncedAt == nil || ipod.current.screen == .settings) {
                    SyncingView(status: library.syncStatus)
                } else if ipod.current.screen == .nowPlaying {
                    NowPlayingView(ipod: ipod, player: player)
                } else {
                    MenuListView(ipod: ipod)
                }
                if let message = ipod.alert ?? library.lastError {
                    AlertBox(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.55), lineWidth: 1.5))
        .environment(\.colorScheme, .light)
    }
}

struct TitleBar: View {
    let title: String
    let isPlaying: Bool

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 44)
            HStack {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.85))
                Spacer()
                BatteryIcon()
            }
            .padding(.horizontal, 7)
        }
        .frame(height: 22)
        .foregroundStyle(.black)
        .background(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.55)).frame(height: 0.5) }
    }
}

struct BatteryIcon: View {
    @State private var level: Float = UIDevice.current.batteryLevel

    var body: some View {
        let fill = level < 0 ? 1 : CGFloat(level)
        HStack(spacing: 0.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).stroke(Color(white: 0.35), lineWidth: 0.8)
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.85, blue: 0.4), Color(red: 0.25, green: 0.6, blue: 0.15)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: max(2, 19 * fill))
                    .padding(1.5)
            }
            .frame(width: 22, height: 10)
            Rectangle().fill(Color(white: 0.35)).frame(width: 1.5, height: 4)
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            level = UIDevice.current.batteryLevel
        }
    }
}

struct MenuListView: View {
    @ObservedObject var ipod: IPod

    var body: some View {
        let level = ipod.current
        let items = ipod.items(for: level.screen)

        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(ipod.visibleRows)
            let showsScrollbar = items.count > ipod.visibleRows

            if items.isEmpty, let message = ipod.emptyMessage(for: level.screen) {
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(white: 0.3))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated().dropFirst(level.top).prefix(ipod.visibleRows)), id: \.offset) { row in
                            MenuRow(item: row.element, isSelected: row.offset == level.selection)
                                .frame(height: rowHeight)
                        }
                        Spacer(minLength: 0)
                    }
                    if showsScrollbar {
                        Scrollbar(total: items.count, visible: ipod.visibleRows, top: level.top)
                            .frame(width: 8)
                    }
                }
            }
        }
    }
}

struct MenuRow: View {
    let item: MenuItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail = item.detail {
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : Color(white: 0.4))
            }
            if item.chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(isSelected ? .white : .black)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isSelected {
                LinearGradient(colors: [Color(red: 0.42, green: 0.69, blue: 0.96), Color(red: 0.13, green: 0.44, blue: 0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

struct Scrollbar: View {
    let total: Int
    let visible: Int
    let top: Int

    var body: some View {
        GeometryReader { geo in
            let thumb = max(12, geo.size.height * CGFloat(visible) / CGFloat(total))
            let offset = (geo.size.height - thumb) * CGFloat(top) / CGFloat(max(1, total - visible))
            ZStack(alignment: .top) {
                Rectangle().fill(Color(white: 0.92))
                    .overlay(alignment: .leading) { Rectangle().fill(Color(white: 0.6)).frame(width: 0.5) }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 5, height: thumb)
                    .offset(y: offset)
            }
        }
    }
}

struct SyncingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large).tint(Color(white: 0.4))
            Text("Syncing…").font(.system(size: 17, weight: .bold))
            Text(status.isEmpty ? "Do not disconnect." : status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AlertBox: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.black)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .padding(16)
    }
}
