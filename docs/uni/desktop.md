# UniVoidDistro: the desktop configuration (RefursWM, RefursLine)

The compositor and the bar come from their own repositories (`desktop/UPSTREAM` names the
snapshots); this distribution's configuration is the two files `desktop/refurswm/src/config.zig`
and `desktop/refursline/src/config.zig`, compiled into the programs by `install/build-desktop.sh`
(ReleaseSafe, the plan's `-Dcpu`). This page is the review of those two files against the
requirement "the fastest, the most optimised, the lightest", done on 2026-10-26: what each
setting costs at run time, what was changed, and what was kept on purpose.

## What a setting can cost

Both configs are `comptime` constants: nothing is parsed at start, nothing is watched, and a
setting that is off is not a branch but code that was never compiled. So the review is not
about parsing cost but about the work a setting makes the programs do while the desktop runs.
The sources were read for every setting that reaches a hot path (`grep cfg.` in `main.zig`,
`output.zig`, `input.zig`, `bar.zig`, `ui.zig`):

| Setting | Where it costs | Decision |
|---|---|---|
| `realtime = false` (RefursWM) | `SCHED_RR` for the compositor would need an `rtprio` limit for the user, which every process of the user could then take; `vh-sched` already gives the compositor an interactive lag bonus and a big core (docs/uni/ROADMAP.md, U4) | kept off: the scheduler does the work without a privilege |
| `allow_tearing = true` | one `wlr_output_test_state` per frame of a fullscreen window that asked for it; nothing for the others (the cache of the test is on upstream's D list) | kept: games only, lowest input latency |
| `focus_follows_mouse = true` | a focus change on crossing a window border: two borders redrawn (2 px) | kept: convenience; the redraw is damage-limited |
| `server_side_decorations = true` | 2 px borders drawn by the compositor instead of each client's title bar (GTK's CSD costs more and renders every frame) | kept |
| `border 2`, `gaps 6/10` | the rendered area; gaps leave the background visible and damaged under moving windows | kept (a gap of 0 saves nothing measurable) |
| `repeat_rate 35`, `repeat_delay 280` | a timer per held key, in the client | kept |
| `cursor_size 24`, `cursor_theme null` | the cursor plane, hardware where the driver has one | kept |
| `outputs = {}` | every monitor at its preferred mode, VRR off | kept: VRR is per monitor and some panels flicker; a later rule may set it from the EDID (hwdb) |
| `theme_hooks_*` (`gsettings`) | one `execve` on a theme toggle, skipped when GTK is not installed | kept |
| `autostart`: pipewire, vh-wlfilter, the bar, swayidle | four processes per session; swayidle is the lock after 5 minutes and before sleep, the idle time coming from the compositor's idle-notify protocol (no polling) | kept: PipeWire sleeps without a stream (`suspend-node`), vh-wlfilter sleeps on its socket |
| `clock_format = .full` (RefursLine) | one timer per minute (`.hms` would be one per second: 60 times the wakeups and redraws) | kept |
| `hover_effect = true` | a redraw of one button on pointer enter and leave; no cost without a pointer over the bar | kept |
| `font_paths` | the first file that exists is opened; each missing one is a failed `openat` | **changed**: Void's DejaVu Sans (the one package `install/packages.sh` installs) first, so the bar opens its font with one `openat` instead of two |
| `launcher_icons = true`, `icon_theme ""` | PNG icons read when the launcher opens, cached | kept |
| `sandbox = true` | seccomp and Landlock on the bar: a few microseconds per filtered call | kept (security; the cost is below the bench's resolution) |
| `title_width 420`, `ws_dot 16`, `ws_active 30` | the area redrawn when the title or the workspace changes | kept |
| battery, Wi-Fi, Bluetooth | re-read on uevent / netlink / D-Bus signals; a 30 s poll only on a kernel without events, 1 s for a few seconds after a radio toggle | kept: the design is event-driven already |
| `power_confirm`, `reboot_cmd = doas -n /usr/bin/reboot` | nothing at run time; with `vh-init` the runit `reboot` works unchanged (init/README.md) | kept |

## What stays with upstream

The measurable work is in the programs, not in the configuration, and it is on the D list of
[docs/ROADMAP.md](../ROADMAP.md#d-refurswm-and-refursline): direct scanout under a fullscreen
window, the tearing test cached, no hit-test under fullscreen, layer configuration only on
change, DPMS; for the bar a commit per frame at most, no blending of the menu background,
XRGB8888, a shared wallpaper buffer, non-blocking radio waits. Those change the sources, go to
the RefursWM and RefursLine repositories and come back through `desktop/build.zig.zon`; the
distribution's configuration is not where they are won.

Measured facts about this desktop so far (upstream, `bench/`, the GF63): the compositor at idle
makes no frame without damage (`output.zig`: no damage, no GPU work), the bar wakes once a minute.
[VERIFY on the rig] idle wakeups per second of the whole session (`tools/vh-session-usage`) with
this configuration; the first number becomes the baseline of the D list.

## The renderer

`vh-session` starts RefursWM with the GPU renderer and falls back to pixman (CPU) when EGL does
not come up (a VM without virgl, simpledrm). The fallback is read from the log of the first
attempt, so a machine without a usable GPU pays one failed start. A later rule of the plan
(`hwdb/gpu.zon`, the DRM driver) can set `WLR_RENDERER=pixman` before the first start on the
drivers known to have no GL (bochs, qxl, simpledrm, virtio-gpu without virgl): [VERIFY] which of
them the installed Mesa handles; until then the fallback is the path.
