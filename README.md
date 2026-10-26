# Liquid Notifications

> **Retired.** The [Notch](https://github.com/Kalinewb/omarchy-notch) now draws
> notifications itself, and this plugin cannot run beside it: both replace
> Omarchy's notification popups. It is kept here for the record and will not
> be listed or updated.

Pitch-black notification popups for Omarchy, always — regardless of your active
theme — with a Dynamic-Island-style entrance animation instead of just popping
into place.

![A notification, settled](preview.png)

## What it does

Replaces Omarchy's built-in notification popups with:

- **True black** (`#000000`), not a near-black pulled from whatever theme
  happens to be active. Text is a fixed light color, chosen for contrast on
  black rather than for theme consistency.
- **A Dynamic-Island-style entrance**: a new notification grows outward from
  a fixed, flush corner of its own footprint — like that corner of the screen
  is what's expanding — rather than simply appearing. The corner it grows
  from stays sharp (no rounding) for as long as the toast is on screen, and
  dismissal shrinks the whole thing back down into it.
- **Configurable anchor corner**: toasts grow out of the top-left,
  top-center, or top-right (default) of the screen. Change it with:
  ```sh
  omarchy-shell notifications setCorner left    # or: center, right
  omarchy-shell notifications getCorner
  ```
  The setting persists across shell restarts (`~/.local/state/omarchy/notifications.json`).
- Everything else works exactly as it did before: icons, summary/body text,
  urgency accent colors, click-to-dismiss, click-to-invoke, hover pauses the
  countdown, Do Not Disturb, and stacking multiple toasts.

**The notification history panel is unaffected** — it keeps its normal,
theme-colored appearance. This plugin only changes the live popup toasts.

## Install

```sh
omarchy plugin add https://github.com/Kalinewb/omarchy-liquid-notifications --enable
```

This replaces Omarchy's built-in notification service the same way any
`clonedFrom` plugin substitutes for what it clones — the stock notification
plugin is automatically disabled while this one is enabled, and switching it
back off restores the stock look.

## How it works

`Service.qml` is a clone of Omarchy's own `omarchy.notifications` plugin
(`omarchy.clonedFrom` in `manifest.json`) with a new entrance/exit animation
on the popup delegate: a `Canvas` paints a rounded shape that grows from a
fixed, zero-radius corner (matching the configured anchor) out to the card's
full footprint on an `OutBack` ease with a modest overshoot — a fast,
slightly springy expand, not a bouncy water-droplet wobble — and shrinks back
into that same corner on a plain `InOutCubic` ease on dismissal.
`components/NotificationCard.qml` gains an opt-in `popupMode` flag so only the
live popup gets the black styling — the history panel keeps using the same
component in its original, theme-colored mode.

The popup `PanelWindow` is `visible` only while there's something to show
(`popupModel.count > 0`), same as upstream — an earlier investigation into a
"the drip doesn't look animated" bug considered making the window
permanently mapped to rule out a surface-creation race, but instrumentation
(timestamped logs across `Component.onCompleted`, the window's
`backingWindowVisibleChanged`, and the `Canvas`'s first `onPaint`) showed the
window becomes visible and starts painting within ~15ms of the popup
appearing — no meaningful race. The actual bug was the entrance easing
front-loading nearly all of its visible motion into the first ~100ms of the
animation's duration, confirmed with rapid (~50ms-apart) screenshot bursts
against a live notification; the fix was pacing, not surface lifecycle.

Because this is a `keepLoaded` service, a plain `rescanPlugins` won't fully
swap it in after an update — a shell restart (`omarchy restart shell`) picks
up a new install or a manual edit cleanly.

## License

MIT — see `LICENSE`.
