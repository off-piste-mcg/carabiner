# Responsive hero beside the left rail — design

**Date:** 2026-08-24
**Status:** Approved (Wisse), pre-implementation
**Prior art:** `2026-08-22-brand-main-window-design.md` (brand canvas),
`docs/superpowers/plans/2026-08-22-brand-main-window.md` (left-rail revision)

## Problem

The main window's hero content (link bar + status line) centers itself across the
**full** window width, while the left rail is an overlay. Two overlaps result:

- **Card open:** the 300pt RECENT GRABS / SETTINGS card (+14pt margin = 314pt)
  covers the link bar's left edge at any window width — at smaller sizes the
  prompt reads "TE YOUR LINK" and a chunk of the field is unreachable.
- **Card closed:** at the 640pt minimum width even the collapsed rail
  (48pt + 14pt margin = 62pt) clips the bar's left edge by a few points, since
  the bar spans `56 … width-56` and the rail spans `14 … 62`.

## Decision (chosen from three options)

**Re-center the hero in the space beside the rail.** Rejected: treating the card
as modal (dims a link bar there is no reason to disable), and a
proportional-width card (more layout logic for no visible gain at our size range).

## Mechanism

All changes in `app/Carabiner/MainWindow/MainView.swift`; nothing in `SideRail`
or the view model.

- `content` gets a **leading inset matching what the rail occupies**:
  - collapsed: **62pt** (48 rail + 14 margin)
  - expanded: **314pt** (300 card + 14 margin)
- The inset is keyed on `model.panel`, so the existing
  `.animation(.easeOut(duration: 0.2), value: model.panel)` on the root ZStack
  animates the bar sliding right/left as the card opens/closes. No new
  animation code.
- **Interior horizontal padding drops from 56pt to 24pt while the panel is
  open** (56 stays when closed). Budget at the 640pt minimum with the card
  open: 640 − 314 = 326pt of canvas; 24pt padding each side leaves a ~278pt
  link bar — tight but fully usable, never covered. The old fixed 56pt would
  have left ~214pt.

## What deliberately does not move

- Corner furniture stays anchored: rotated version string (right edge),
  hotkey + wordmark + clock (bottom-right — already clear of the card at
  minimum width).
- Tap-outside-to-collapse, Esc, drag-and-drop: unchanged.
- Card width stays fixed at 300pt; the rail's own geometry is untouched.

## Testing

The inset is a two-case constant; a unit test on it would pass with the wiring
deleted (gotcha #34 family — theatre). Verification is visual, on a built app:

1. Default size (720×460): open/close each card — bar re-centers, animation clean.
2. Minimum size (640×420): card open — full prompt text visible, field and GRAB
   button usable, nothing covered.
3. Card closed at minimum size — bar clear of the collapsed rail.
