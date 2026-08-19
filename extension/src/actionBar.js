// Finds the Save (bookmark) button inside a post, so the Carabiner button can sit beside it
// instead of in the post's top-right corner.
//
// Two constraints shaped this, and both rule out the obvious approaches:
//
//  1. NO LABEL MATCHING. `aria-label` is localized — on the machine this was written for it
//     reads "Opslaan", not "Save". Matching label text works on exactly one language's
//     Instagram, which is the same trap slideIndex.js documents for its carousel dots.
//  2. NO GEOMETRY. Grouping buttons into rows by their rects would need layout, and jsdom
//     has none — `getBoundingClientRect()` returns zeros there, so such a rule could never
//     be tested against the captured fixtures and would be verified only by eye. The
//     structure below is pure DOM, so the real markup can check it (gotcha #31).
//
// The rule, measured against the real captured fixtures 2026-08-19:
//   the first <section> holding at least MIN_ACTIONS outermost icon buttons is the action
//   bar, and Save is the LAST of them.
//
//   feed-post.html   → section 0: like, comment, repost, share, Opslaan   (5, Save last)
//   permalink.html   → section 0: like, comment, repost, Opslaan          (4, Save last)
//   grid-thumb.html  → no <section> at all                                → null, corner
//
// Note what the threshold is doing: permalink.html carries FOURTEEN like buttons (one per
// comment) and a separate one-button section for the emoji picker. Requiring three or more
// icon buttons in one section is what rejects both without knowing anything about comments.

/// Fewer than this and it is not an action bar — it is a stray control. Instagram has
/// shipped both 4- and 5-button bars (share is absent on the permalink fixture), so this
/// must stay below four.
const MIN_ACTIONS = 3;

/**
 * @param {Element} container A post container (an <article>, or a permalink <a>).
 * @returns {Element|null} The Save button, or null when this post has no action bar —
 *   profile-grid thumbnails genuinely have none, and callers must fall back rather than
 *   hide the button (a markup change should demote the position, never remove the button).
 */
export function findSaveButton(container) {
  for (const section of container.querySelectorAll("section")) {
    const withIcons = Array.from(section.querySelectorAll('[role="button"]'))
      .filter((b) => b.querySelector("svg"));
    // The real markup nests `div[role=button]` directly inside `div[role=button]`, so the
    // inner copies must be dropped or every button counts twice and the "last" one is an
    // inner wrapper rather than the button itself.
    const outermost = withIcons.filter((b) => !withIcons.some((o) => o !== b && o.contains(b)));
    if (outermost.length >= MIN_ACTIONS) return outermost[outermost.length - 1];
  }
  return null;
}

/**
 * Where to put a `size`-square button so it sits just left of `saveRect`, centred on it.
 * Split out from the DOM search purely so it can be tested without layout.
 *
 * @param {{left:number, top:number, height:number}} saveRect
 * @returns {{x:number, y:number}} Viewport coordinates, rounded (the host is positioned
 *   with a transform, and sub-pixel values there cost a blurry icon for nothing).
 */
export function saveAnchorPosition(saveRect, size, gap) {
  return {
    x: Math.round(saveRect.left - size - gap),
    y: Math.round(saveRect.top + (saveRect.height - size) / 2),
  };
}
