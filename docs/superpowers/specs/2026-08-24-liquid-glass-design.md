# Liquid Glass on the main window — design

**Date:** 2026-08-24
**Status:** Approved (Wisse), pre-implementation
**Prior art:** `2026-08-22-brand-main-window-design.md` (brand canvas, materials)

## Decisions (made with Wisse)

- **Liquid Glass** (macOS 26's design language, `.glassEffect()`) over tuned
  classic materials.
- **Deployment target stays 13.0** — every glass surface is gated with
  `if #available(macOS 26.0, *)`; older systems keep exactly today's look.
- **Structure only:** the rail, the expanded RECENT GRABS / SETTINGS card, and
  the link-bar field. The yellow pills (GRAB / ALLOW / DISABLE / ✕), the hollow
  MANAGE pill, and the corner furniture are brand identity and stay untouched.

## Mechanism

Three gated sites, fallbacks inline (they differ, so a shared helper would just
re-encode the call sites as parameters):

| Surface | File | macOS 26 | Fallback (today's code, unchanged) |
|---|---|---|---|
| Rail | `SideRail.swift` `rail` | `.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 22))` | `.background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))` |
| Expanded card | `SideRail.swift` `expandedCard` | same as rail | same as rail |
| Link field | `MainView.swift` `linkBar` | `.glassEffect(.clear, in: Capsule())` | `.background(Capsule().fill(.white.opacity(0.55)))` |

**Corrected 2026-08-24, after shipping `.regular` first:** `.regular` glass rendered
but was visually indistinguishable from the old `.regularMaterial` frost over this
soft gradient — Wisse reported "still the grayish bg" and a tint experiment proved
the glass branch was executing fine. The variant is `.clear` (transparent, strong
lensing), which is visibly glass on this canvas. If a future macOS makes `.clear`
too low-contrast for the card text, tune with `.tint()` before reaching for
`.regular`, which reads as frost here.

No `GlassEffectContainer`: the shapes never approach each other, so there is
nothing to blend or morph. The card/rail open-close transition
(`.move + .opacity`, animated on `model.panel`) is unchanged.

## Risks / verification

- **SDK availability is the first-build question:** compiling `.glassEffect`
  needs the macOS 26 SDK (Xcode 26). If the installed Xcode lacks it, stop and
  report — no workaround, no polyfill.
- **Glass path:** full visual verification on this machine (26.5.2) — rail,
  card, and field render refractive glass over the gradient canvas; open/close
  animation still clean; text in the field legible.
- **Fallback path:** unverifiable here (no pre-26 install exists). Accepted:
  the `else` branches are byte-identical to shipping code, so the residual risk
  is compile-level, which the build catches.
- **No unit tests** — rendering only, no decision to pin; an availability-gate
  test would be theatre.
