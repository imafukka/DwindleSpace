// Fork(dwindle): consecutive refresh ticks a window has been offscreen-while-tiled. Debounce so
// freshly created windows (briefly offscreen at creation) aren't mistaken for background native tabs.
@MainActor private var nativeTabOffscreenTicks: [UInt32: Int] = [:]
private let nativeTabOffscreenThreshold = 2

@MainActor
func normalizeLayoutReason() async throws {
    // Fork(dwindle): computed once per tick, only when the native-tabs feature is enabled.
    let onscreenIds: Set<UInt32> = config.macosNativeTabs ? getOnscreenWindowIds() : []
    if config.macosNativeTabs { // keep the debounce map from leaking dead window ids
        let alive = Set(MacWindow.allWindowsMap.keys)
        nativeTabOffscreenTicks = nativeTabOffscreenTicks.filter { alive.contains($0.key) }
    }
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, onscreenIds: onscreenIds)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self), onscreenIds: onscreenIds)
    try await validateStillPopups()
}

// Fork(dwindle): a window is a background native macOS tab if it lives in the tiling tree on a
// visible workspace, isn't in any macOS special state, and macOS reports it off-screen. Debounced.
@MainActor
private func isBackgroundNativeTab(
    _ window: Window,
    parent: NonLeafTreeNodeObject,
    isMacosFullscreen: Bool,
    isMacosMinimized: Bool,
    isMacosWindowOfHiddenApp: Bool,
    onscreenIds: Set<UInt32>,
) -> Bool {
    guard config.macosNativeTabs,
          !isMacosFullscreen, !isMacosMinimized, !isMacosWindowOfHiddenApp,
          parent.kind == .tilingContainer, // phantom tiles only happen in tiling
          window.nodeWorkspace?.isVisible == true, // never touch windows on hidden workspaces
          !onscreenIds.contains(window.windowId)
    else {
        nativeTabOffscreenTicks.removeValue(forKey: window.windowId)
        return false
    }
    let n = (nativeTabOffscreenTicks[window.windowId] ?? 0) + 1
    nativeTabOffscreenTicks[window.windowId] = n
    return n >= nativeTabOffscreenThreshold
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], onscreenIds: Set<UInt32>) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                let isBgNativeTab = isBackgroundNativeTab(window, parent: parent, isMacosFullscreen: isMacosFullscreen,
                    isMacosMinimized: isMacosMinimized, isMacosWindowOfHiddenApp: isMacosWindowOfHiddenApp, onscreenIds: onscreenIds)
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isBgNativeTab:
                        // Fork(dwindle): park the background tab out of tiling (reuse the minimized
                        // container as physical storage; the .macosNativeTab reason routes its return).
                        window.layoutReason = .macosNativeTab(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
            case .macosNativeTab(let prevParentKind):
                // Fork(dwindle): the tab came back to the foreground (on-screen) — return it to tiling.
                if onscreenIds.contains(window.windowId) {
                    nativeTabOffscreenTicks.removeValue(forKey: window.windowId)
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
