# Liquid Notifications

Pitch-black notification popups for Omarchy, always — regardless of your active
theme — with a liquid-drip entrance animation instead of just popping into
place.

![A notification, settled](preview.png)

## What it does

Replaces Omarchy's built-in notification popups with:

- **True black** (`#000000`), not a near-black pulled from whatever theme
  happens to be active. Text is a fixed light color, chosen for contrast on
  black rather than for theme consistency.
- **A liquid-drip entrance**: a new notification stretches down from the top
  of the screen like a drop of liquid, widening into shape with a bit of
  elastic overshoot as it lands, rather than simply appearing. Dismissal
  retracts the same way.
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
on the popup delegate: an `OutCubic` stretch into shape, a short `OutElastic`
landing bounce, and a matching `InBack` retract on dismissal, all driving a
`Canvas` that paints the teardrop/blob shape converging on the settled card.
`components/NotificationCard.qml` gains an opt-in `popupMode` flag so only the
live popup gets the black styling — the history panel keeps using the same
component in its original, theme-colored mode.

Because this is a `keepLoaded` service, a plain `rescanPlugins` won't fully
swap it in after an update — a shell restart (`omarchy restart shell`) picks
up a new install or a manual edit cleanly.

## License

MIT — see `LICENSE`.
