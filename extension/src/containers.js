import { permalinkFromHref } from "./shortcode.js";

// Pure: which elements in a document should be treated as "post containers" eligible for
// a Carabiner button.
//
// Extracted for fix round 1, Finding 1 (Important, DEMONSTRATED against this repo's own
// fixtures): the naive selector `article, a[href^='/p/'], a[href^='/reel/']` matched BOTH
// an <article> and the permalink anchor nested inside it, so a single feed post got two
// buttons — the second forced `position:relative` onto the timestamp anchor and drew a
// 28px circle on top of the timestamp text.
//
// Rewritten for fix round 3: the old selector used CSS prefix-match attribute selectors
// (`a[href^='/p/']`), which can only test the START of an href. Instagram's profile grid
// prefixes the account handle (`/liverpoolfc/p/Db-bJHcjkxw/`), so a prefix selector can
// express "bare form" or "handle-prefixed form" but not both at once — and matched NONE
// of a real profile grid, which is why the button never appeared there at all (measured:
// 0 containers, 0 buttons, on a real captured grid page). A CSS selector cannot express
// "the href, once you strip an optional leading handle segment, starts with p/ or
// reel/" — so this now selects EVERY anchor with an href at all and asks the single
// source of truth for that question, `permalinkFromHref` (extension/src/shortcode.js),
// whether the anchor's OWN href resolves to a post. That also, for free, makes a comment
// permalink (`/p/CODE/c/<comment-id>/`, found on a real open-post page — 12 of them, one
// per top-level comment, all for the SAME post) count as a match — correct, since it IS a
// link to that post — while still being just one candidate that gets deduped against its
// enclosing <article> like any other, rather than becoming its own separate button.
//
// Rule: an <article> is a container. A permalink-shaped anchor is a container only when
// it has no enclosing <article> — Instagram's grid/tagged-photos view, where the anchor
// IS the whole tile with no <article> wrapper. An anchor nested inside an <article> is
// redundant: the article itself is (or will be) the element that gets the button.
//
// Exception, measured live 2026-08-17: nothing inside a `[role=dialog]` is a container.
// Instagram's post MODAL (profile grid → click a tile) wraps the whole dialog in an
// <article> — 1600×859 on a 1728×907 viewport, i.e. the article IS the modal — so
// "button at the container's top-right" put our button at the top-right of the SCREEN,
// beside/over Instagram's own close X (ours at 1624,32; the X at 1489,23), and the
// user could no longer close the post. Losing the button there costs nothing: the
// moment the modal opens, the tab URL becomes the post's permalink, which is exactly
// the case the hotkey already handles — the extension exists for the pages where the
// tab URL is useless (feed, grid), and a modal is not one of them. If Instagram ever
// drops `role=dialog` from the modal, this degrades to the old misplaced-button
// behaviour, not to anything worse.
export function selectContainers(root) {
  const candidates = root.querySelectorAll("article, a[href]");
  const result = [];
  for (const el of candidates) {
    if (el.closest("[role=dialog]")) continue; // the post modal — see above
    if (el.tagName === "A") {
      if (el.closest("article")) continue; // redundant — the enclosing article gets the button
      if (!permalinkFromHref(el.getAttribute("href"))) continue; // not a post link at all
    }
    result.push(el);
  }
  return result;
}
