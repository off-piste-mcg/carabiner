// Instagram's markup changes without warning, so this is deliberately forgiving: walk up
// looking for a post container, then find the first anchor that looks like a permalink.
// It must NEVER throw — a null return simply means "no button here".
//
// Fix round 3: Instagram uses TWO permalink shapes, not one. The home feed really does
// use the bare form (`/p/CODE/`), but a profile grid prefixes the account handle
// (`/<handle>/p/CODE/`, e.g. `/liverpoolfc/p/Db-bJHcjkxw/`) — measured from a real
// captured profile grid page. The old pattern was anchored at the path start and matched
// NOTHING on a grid, so the button never appeared on any profile page at all — one of the
// three surfaces this feature targets, 100% broken, silently, and no synthetic fixture
// caught it because the synthetic grid fixture encoded the same wrong assumption the code
// did. `(?:[\w.-]+\/)?` is the optional handle segment; it must not be able to swallow the
// real `(p|reel|reels|tv)` segment for the bare form. It can't: regex backtracking means
// that for `/p/CODE/`, the engine first tries consuming "p/" as the handle (greedy), finds
// nothing left that matches `(p|reel|reels|tv)`, backs off to a zero-width match for the
// optional group, and only then matches "p" as the real segment — verified explicitly in
// shortcode.test.js, including a pathological handle that itself starts with "reel".
const POST_HREF = /^\/(?:[\w.-]+\/)?(p|reel|reels|tv)\/([\w-]+)/;

export function permalinkFor(element) {
  if (!element) return null;
  let node = element;
  for (let depth = 0; node && depth < 12; depth++) {
    const link = findPostLink(node);
    if (link) return link;
    node = node.parentElement;
  }
  return null;
}

/**
 * Does this raw href attribute (relative or absolute, handle-prefixed or bare) identify
 * an Instagram post/reel permalink? Returns the canonical, handle-stripped
 * `https://www.instagram.com/p/CODE/` (or `/reel/CODE/`) form, or null.
 *
 * Exported (fix round 3) so containers.js can ask "is this anchor's OWN href a post
 * link", independent of permalinkFor's ancestor-climbing — the two are different
 * questions, and containers.js needs the first one, not the second.
 */
export function permalinkFromHref(href) {
  const match = POST_HREF.exec(href || "");
  if (!match) return null;
  return `https://www.instagram.com/${match[1] === "reels" ? "reel" : match[1]}/${match[2]}/`;
}

function findPostLink(node) {
  if (typeof node.querySelectorAll !== "function") return null;
  const candidates = [];
  if (node.tagName === "A") candidates.push(node);
  candidates.push(...node.querySelectorAll("a[href]"));
  for (const a of candidates) {
    // getAttribute, not .href: jsdom and about:blank resolve relative URLs differently,
    // and the raw attribute is what Instagram actually writes.
    const canonical = permalinkFromHref(a.getAttribute("href"));
    if (canonical) return canonical;
  }
  return null;
}
