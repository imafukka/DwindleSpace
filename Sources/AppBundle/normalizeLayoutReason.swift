// Fork(dwindle): consecutive refresh ticks a window has been offscreen-while-tiled. Only NEW windows
// (never yet seen on-screen) are debounced — a freshly created window can be briefly offscreen while
// it settles. An established window that goes offscreen is a tab going to the background and is parked
// on the same tick (before layout), so there is no visible relayout jump.
@MainActor private var nativeTabOffscreenTicks: [UInt32: Int] = [:]
@MainActor private var nativeTabSeenOnscreen: Set<UInt32> = []
private let nativeTabOffscreenThreshold = 2

// Fork(dwindle): a tiling slot vacated on this tick by a tab that went to the background. The tab of the
// same app that came to the foreground takes this exact slot (parent, index, weight) instead of a fresh
// dwindle insertion — otherwise it would split whatever window is MRU now, using that window's stale
// pre-layout rect, and switching tabs would reshape the layout.
private struct VacatedNativeTabSlot {
    let pid: Int32
    let binding: BindingData
    let rect: Rect?
}

@MainActor
func normalizeLayoutReason() async throws {
    // Fork(dwindle): computed once per tick, only when the native-tabs feature is enabled.
    let onscreenIds: Set<UInt32> = config.macosNativeTabs ? getOnscreenWindowIds() : []
    if config.macosNativeTabs { // keep the tracking maps from leaking dead window ids
        let alive = Set(MacWindow.allWindowsMap.keys)
        nativeTabOffscreenTicks = nativeTabOffscreenTicks.filter { alive.contains($0.key) }
        nativeTabSeenOnscreen = nativeTabSeenOnscreen.filter { alive.contains($0) }
    }
    // Fork(dwindle): background tabs are parked in the workspace pass, foreground tabs return in the
    // minimized pass after it — so a returning tab always sees the slots vacated on this tick.
    var vacatedTabSlots: [VacatedNativeTabSlot] = []
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, onscreenIds: onscreenIds, vacatedTabSlots: &vacatedTabSlots)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self), onscreenIds: onscreenIds, vacatedTabSlots: &vacatedTabSlots)
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
    let id = window.windowId
    // A window we've seen genuinely on-screen is an established window; when it later goes off-screen
    // it's a tab that went to the background, so it can be parked immediately.
    if onscreenIds.contains(id) { nativeTabSeenOnscreen.insert(id) }
    guard config.macosNativeTabs,
          !isMacosFullscreen, !isMacosMinimized, !isMacosWindowOfHiddenApp,
          parent.kind == .tilingContainer, // phantom tiles only happen in tiling
          window.nodeWorkspace?.isVisible == true, // never touch windows on hidden workspaces
          !onscreenIds.contains(id)
    else {
        nativeTabOffscreenTicks.removeValue(forKey: id)
        return false
    }
    // Established window (was on-screen before) → park now, on the same tick, before layout runs.
    if nativeTabSeenOnscreen.contains(id) { return true }
    // Never seen on-screen yet (freshly created?) → debounce so it isn't parked while it's settling.
    let n = (nativeTabOffscreenTicks[id] ?? 0) + 1
    nativeTabOffscreenTicks[id] = n
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
private func _normalizeLayoutReason(
    workspace: Workspace,
    windows: [Window],
    onscreenIds: Set<UInt32>,
    vacatedTabSlots: inout [VacatedNativeTabSlot],
) async throws {
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
                        // The vacated slot is remembered for the foreground tab returning on this tick.
                        window.layoutReason = .macosNativeTab(prevParentKind: parent.kind)
                        let rect = window.lastAppliedLayoutPhysicalRect
                        if let slot = window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST) {
                            vacatedTabSlots.append(VacatedNativeTabSlot(pid: window.app.pid, binding: slot, rect: rect))
                        }
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
            case .macosNativeTab(let prevParentKind):
                // Fork(dwindle): the tab came back to the foreground (on-screen) — return it to tiling,
                // into the slot of the tab it replaced if one was vacated on this tick.
                if onscreenIds.contains(window.windowId) {
                    nativeTabOffscreenTicks.removeValue(forKey: window.windowId)
                    if let slot = try await takeVacatedNativeTabSlot(for: window, &vacatedTabSlots) {
                        window.layoutReason = .standard
                        window.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: min(slot.index, slot.parent.children.count))
                    } else {
                        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                    }
                }
        }
    }
}

// Fork(dwindle): pick a slot vacated on this tick by a background tab of the same app. Tabs of one group
// share a frame, so when several slots match (several tabbed windows of one app switched at once) the
// one whose tile is closest to the returning window's frame wins.
@MainActor
private func takeVacatedNativeTabSlot(for window: Window, _ slots: inout [VacatedNativeTabSlot]) async throws -> BindingData? {
    let candidates = slots.indices.filter { i in
        slots[i].pid == window.app.pid && slots[i].binding.parent is TilingContainer && slots[i].binding.parent.nodeWorkspace != nil
    }
    guard var best = candidates.first else { return nil }
    if candidates.count > 1, let rect = try await window.getAxRect(.cancellable) {
        best = candidates.minBy { i in slots[i].rect.map { ($0.center - rect.center).vectorLength } ?? .infinity } ?? best
    }
    return slots.remove(at: best).binding
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
