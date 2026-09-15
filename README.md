# DwindleSpace

A minimal fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace) that adds
**dwindle / bsp-style automatic window insertion** (Hyprland / bspwm feel) and
**native macOS tabs that don't eat tiles** — with no SIP disabling, just like upstream.

Stock AeroSpace uses an i3-style tiling model: you split containers manually and plan
where the next window will land. DwindleSpace swaps the insertion policy for a
**dwindle** one — a new window splits the currently focused tile, and the split
direction is chosen automatically from that tile's aspect ratio. You never plan the
layout, you just open windows.

Everything else — virtual workspaces, the Accessibility plumbing and its years of
workarounds, gaps, autofloat, window rules, the accordion layout, the CLI and the
TOML config — is inherited unchanged from upstream.

## What's different from upstream

The fork is intentionally small: two config flags, a new insertion policy and a couple
of targeted fixes.

- **`window-insertion = 'i3' | 'dwindle'`** config flag. Default is `i3`, so the fork
  is a drop-in; set it to `dwindle` to get bsp-style insertion.
- **Dwindle insertion.** A new tiling window wraps the most-recently-focused window in
  a fresh binary container. Orientation comes from the focused tile's physical aspect
  ratio (wide tile → windows side by side, tall tile → stacked), split 50/50. Inside an
  accordion container the previous i3 behavior is kept (the new window joins the stack).
- **bsp-style close for free.** Closing a window collapses its container and the sibling
  reclaims the space. This falls straight out of AeroSpace's existing
  flatten-normalization, so it needs no extra code — keep
  `enable-normalization-flatten-containers = true`.
- **`macos-native-tabs = true` — background tabs don't get phantom tiles.** macOS native
  tabs (Finder, Preview, TextEdit, … or any app with "Prefer tabs: Always") are separate
  windows to the Accessibility API, so upstream gives every background tab its own empty
  tile ([upstream issue #68](https://github.com/nikitabobko/AeroSpace/issues/68)). The
  fork asks the window server which windows are actually on screen
  (`CGWindowListCopyWindowInfo`, `kCGWindowIsOnscreen`). A tiled window on a visible
  workspace that macOS reports as off-screen — and that isn't minimized, fullscreen or
  owned by a hidden app — is a background tab, so it is parked out of the layout. When
  you switch tabs, the tab coming to the front takes the exact tile of the one going to
  the back, so switching tabs never reshapes the layout. Default is `false`.
- **Close fallback for borderless windows.** Windows that hide their title bar (e.g.
  kitty with `hide_window_decorations`) expose no AXCloseButton, so upstream's `close`
  was a silent no-op on them. This fork falls back to the standard macOS ⌘W
  ("Close Window") shortcut for those windows.

The whole diff against upstream is about 200 lines across `Config.swift`,
`parseConfig.swift`, `MacWindow.swift`, `MacApp.swift`, `Window.swift`,
`normalizeLayoutReason.swift` and the new `onscreenWindowsCache.swift`. Dwindle and
native-tab handling are behind flags that default to upstream behavior; the close
fallback only kicks in where upstream's `close` did nothing.

### Why the tab detection is safe

AeroSpace hides windows of inactive workspaces by moving them into a screen corner with
a sliver still visible, so macOS keeps reporting them as on-screen — they are never
mistaken for background tabs. On top of that, detection only runs for windows on visible
workspaces. A brand-new window that is briefly off-screen while it opens is not parked
right away: windows that have never been seen on screen get a short debounce.

## Recommended config

With `window-insertion = 'dwindle'`, disable opposite-orientation normalization
(dwindle already picks orientation by aspect, so forced alternation fights it) and keep
flatten normalization on (that's what gives the bsp-style close):

```toml
config-version = 2

window-insertion = 'dwindle'
macos-native-tabs = true
enable-normalization-flatten-containers = true
enable-normalization-opposite-orientation-for-nested-containers = false

[gaps]
inner.horizontal = 12
inner.vertical = 12
outer.left = 12
outer.right = 12
outer.top = 12
outer.bottom = 12
```

The `join-with` key bindings from the upstream sample config are no longer needed
(dwindle picks the split for you), so you can drop them.

## Build & run

With full Xcode installed, upstream's `./build-debug.sh` works as usual. With only the
Command Line Tools, build the debug binaries directly with SwiftPM (this skips the test
target, which needs XCTest from Xcode; `generate.sh` needs bash 5, e.g.
`brew install bash`):

```bash
./generate.sh --ignore-xcodeproj --ignore-cmd-help
swift build
rm -rf .debug && mkdir .debug
cp .build/debug/aerospace .build/debug/AeroSpaceApp .debug/
./.debug/AeroSpaceApp --config-path /path/to/your.toml
```

The debug build uses its own bundle id (`bobko.aerospace.debug`) and its own CLI socket,
so it can run side by side with a stock AeroSpace install without clashing.

An unsigned binary gets a new code hash on every build, so macOS asks for Accessibility
permission again after each rebuild. To avoid that, create the self-signed
`aerospace-codesign-certificate` as described in upstream's
[dev-docs](dev-docs/development.md#2-create-codesign-certificate) and sign the binary
after copying it:

```bash
codesign -s aerospace-codesign-certificate -i bobko.aerospace.debug --force .debug/AeroSpaceApp
```

## Relationship to upstream

DwindleSpace tracks [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace)
and aims to stay a small patch rather than a divergent rewrite. Upstream changes are
merged in regularly (last sync: September 2026, AeroSpace `main` after v0.21.3-Beta).
The CLI and events (`list-workspaces`, `list-windows`, `workspace N`,
`exec-on-workspace-change`) are unchanged, so tools like sketchybar keep working against
it.

## License

MIT, same as upstream — see [LICENSE.txt](LICENSE.txt). Copyright © Nikita Bobko and
contributors.
