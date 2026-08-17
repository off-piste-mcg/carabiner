// Which carousel slide is the user actually looking at?
//
// Without this, the button always grabbed slide 1: shortcode.js canonicalises every match
// to a bare `https://www.instagram.com/p/CODE/`, and per gotcha #15 the app reads a missing
// `img_index` as slide 1. So "This slide" on a feed carousel silently saved the wrong file
// and still reported success — found 2026-08-17 by a user test, not by any test in here.
//
// Two independent sources, deliberately ordered (see the design doc):
//   1. the page URL's `img_index` — what the app has always trusted, and what the hotkey
//      path feeds it; authoritative wherever it exists (permalink pages).
//   2. the active carousel dot — the only source on a feed, where the URL is just
//      `instagram.com/`. Instagram marks it semantically, `aria-current="step"` on a
//      `<button aria-label="Go to slide N">`, and the dots sit INSIDE the post container
//      the button is already keyed on (verified against the real captured fixture).
//
// Same contract as shortcode.js: NEVER throws, and `null` means "no opinion" — never
// "slide 1". Collapsing those two states is exactly the bug this module exists to fix.
//
// Callers must resolve at CLICK time, not attach time — see content.js.

const SLIDE_LABEL = /slide\s+(\d+)/i;

/** `null` unless `raw` is a positive integer. Deliberately strict: "0", "-2", "1.5" are not slides. */
function positiveInt(raw) {
  if (!/^\d+$/.test(String(raw).trim())) return null;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= 1 ? n : null;
}

/**
 * @param {string} search a `location.search`-shaped string, e.g. "?img_index=3"
 * @returns {number|null}
 */
export function slideIndexFromSearch(search) {
  if (typeof search !== "string" || search === "") return null;
  // No decodeURIComponent: a slide index is digits, and decodeURIComponent THROWS on
  // malformed input ("%"), which would violate this module's never-throw contract for
  // nothing in return.
  const match = /[?&]img_index=([^&]*)/.exec(search);
  return match ? positiveInt(match[1]) : null;
}

/**
 * @param {Element} element the post container
 * @returns {number|null} `null` unless EXACTLY one dot is active — zero means "not a
 *   carousel, or Instagram changed the markup", more than one means we do not understand
 *   this page well enough to answer, and guessing is how the original bug felt to a user.
 */
export function slideIndexFromContainer(element) {
  if (!element || typeof element.querySelectorAll !== "function") return null;
  const active = element.querySelectorAll('button[aria-current="step"]');
  if (active.length !== 1) return null;
  const match = SLIDE_LABEL.exec(active[0].getAttribute("aria-label") || "");
  return match ? positiveInt(match[1]) : null;
}

/**
 * @param {string} permalink the canonical, query-less form from shortcode.js
 * @param {{search?: string, container?: Element}} [sources]
 * @returns {string} the permalink, with `?img_index=N` appended when a slide is known.
 */
export function grabUrlFor(permalink, sources = {}) {
  if (typeof permalink !== "string" || permalink === "") return permalink;
  const fromSearch = slideIndexFromSearch(sources.search);
  const index = fromSearch === null ? slideIndexFromContainer(sources.container) : fromSearch;
  // Appends even when the answer is 1 — "we know it is slide 1" and "we have no idea" are
  // different states, and the permalink is always query-less here, so this is a plain
  // append and never a query-string merge.
  return index === null ? permalink : `${permalink}?img_index=${index}`;
}
