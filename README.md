# DwindleSpace

A minimal fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace) that adds
**dwindle / bsp-style automatic window insertion** (Hyprland / bspwm feel) — with no
SIP disabling, just like upstream.

Stock AeroSpace uses an i3-style tiling model: you split containers manually and plan
where the next window will land. DwindleSpace swaps the insertion policy for a
**dwindle** one — a new window splits the currently focused tile, and the split
direction is chosen automatically from that tile's aspect ratio. You never plan the
layout, you just open windows.

Everything else — virtual workspaces, the Accessibility plumbing and its years of
workarounds, gaps, autofloat, window rules, the accordion layout, the CLI and the
TOML config — is inherited unchanged from upstream.

## What's different from upstream

The fork is intentionally tiny: a config flag plus a new insertion policy.

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
- **Close fallback for borderless windows.** Windows that hide their title bar (e.g.
  kitty with `hide_window_decorations`) expose no AXCloseButton, so upstream's `close`
  was a silent no-op on them. This fork falls back to the standard macOS ⌘W
  ("Close Window") shortcut for those windows.

The whole diff is a few dozen lines across `Config.swift`, `parseConfig.swift`,
`MacWindow.swift` and `MacApp.swift`.

## Recommended config for dwindle

With `window-insertion = 'dwindle'`, disable opposite-orientation normalization
(dwindle already picks orientation by aspect, so forced alternation fights it) and keep
flatten normalization on (that's what gives the bsp-style close):

```toml
config-version = 2

window-insertion = 'dwindle'
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

No full Xcode required — Command Line Tools are enough (the test target that needs
XCTest is skipped):

```bash
./build.sh                                  # produces .debug/{aerospace,AeroSpaceApp}
./.debug/AeroSpaceApp --config-path /path/to/your.toml
```

The debug build uses its own bundle id (`bobko.aerospace.debug`) and its own CLI socket,
so it can run side by side with a stock AeroSpace install without clashing. The binary is
unsigned, so macOS asks for Accessibility permission again after each rebuild.

## Relationship to upstream

DwindleSpace tracks [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace)
and aims to stay a small, rebase-friendly patch rather than a divergent rewrite. The CLI
and events (`list-workspaces`, `list-windows`, `workspace N`, `exec-on-workspace-change`)
are unchanged, so tools like sketchybar keep working against it.

## License

MIT, same as upstream — see [LICENSE.txt](LICENSE.txt). Copyright © Nikita Bobko and
contributors.
