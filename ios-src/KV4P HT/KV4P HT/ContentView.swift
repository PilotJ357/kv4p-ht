import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var store = RadioStore()
    @State private var selectedTab: Tab = .voice

    enum Tab: String, CaseIterable {
        case voice, aprs, map, memories, more
        var label: String {
            switch self {
            case .voice:    return "Voice"
            case .aprs:     return "APRS"
            case .map:      return "Map"
            case .memories: return "Memories"
            case .more:     return "More"
            }
        }
        var icon: String {
            switch self {
            case .voice:    return "waveform"
            case .aprs:     return "message"
            case .map:      return "map"
            case .memories: return "star"
            case .more:     return "ellipsis.circle"
            }
        }
    }

    private var theme: AppTheme { AppTheme.forMode(store.themeMode, systemColorScheme: systemColorScheme) }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                VoiceView(store: store)
            }
            .tabItem { Label(Tab.voice.label, systemImage: Tab.voice.icon) }
            .tag(Tab.voice)

            NavigationStack {
                APRSView(store: store)
            }
            .tabItem { Label(Tab.aprs.label, systemImage: Tab.aprs.icon) }
            .tag(Tab.aprs)

            NavigationStack {
                APRSMapView(store: store)
            }
            .tabItem { Label(Tab.map.label, systemImage: Tab.map.icon) }
            .tag(Tab.map)

            NavigationStack {
                MemoriesView(store: store)
            }
            .tabItem { Label(Tab.memories.label, systemImage: Tab.memories.icon) }
            .tag(Tab.memories)

            NavigationStack {
                MoreView(store: store)
            }
            .tabItem { Label(Tab.more.label, systemImage: Tab.more.icon) }
            .tag(Tab.more)
        }
        .environment(\.theme, theme)
        .preferredColorScheme(store.themeMode == .system ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.accent)
        .onAppear { store.theme = theme }
        .onChange(of: theme.mode) { _, _ in store.theme = theme }
        .onChange(of: systemColorScheme) { _, _ in store.theme = theme }
        .onChange(of: store.pendingMapFocusID) { _, id in
            if id != nil { selectedTab = .map }
        }
        // APRS Live Activity: only while connected and tuned to an APRS freq.
        .onChange(of: store.ble.bleState) { _, _ in store.syncLiveActivity() }
        .onChange(of: store.isAprsActive) { _, _ in store.syncLiveActivity() }
        .onChange(of: store.aprsNotify.liveActivityEnabled) { _, _ in store.syncLiveActivity() }
        .onOpenURL { url in
            if url.scheme == "kv4pht", url.host == "aprs" { selectedTab = .aprs }
        }
        .onChange(of: scenePhase) { _, phase in
            // .inactive is ignored — it fires for Control Center, incoming
            // calls, etc. Audio/BLE deliberately keep running in background.
            switch phase {
            case .background: store.enterBackground()
            case .active:     store.enterForeground()
            default:          break
            }
        }
        .alert("Can't tune", isPresented: Binding(
            get: { store.tuneNotice != nil },
            set: { if !$0 { store.tuneNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.tuneNotice ?? "")
        }
    }
}

#Preview("Dark") {
    ContentView()
}

#Preview("Light") {
    ContentView()
        .onAppear {
            // Preview helper — set via store after init
        }
}
