// Pure: which elements in a document should be treated as "post containers" eligible for
// a Carabiner button.
//
// Extracted for fix round 1, Finding 1 (Important, DEMONSTRATED against this repo's own
// fixtures): the naive selector `article, a[href^='/p/'], a[href^='/reel/']` matched BOTH
// an <article> and the permalink anchor nested inside it, so a single feed post got two
// buttons — the second forced `position:relative` onto the timestamp anchor and drew a
// 28px circle on top of the timestamp text. Measured: feed-post.html and permalink.html
// went from 2 buttons to 1 with the fix below; grid-thumb.html was already correct at 4
// (four distinct posts, no <article> wrapper in that view at all) and stays 4.
//
// Rule: an <article> is a container. A permalink anchor is a container only when it has
// no enclosing <article> — Instagram's grid/tagged-photos view, where the anchor IS the
// whole tile with no <article> wrapper. An anchor nested inside an <article> is
// redundant: the article itself is (or will be) the element that gets the button.
export function selectContainers(root) {
  const candidates = root.querySelectorAll("article, a[href^='/p/'], a[href^='/reel/']");
  const result = [];
  for (const el of candidates) {
    if (el.tagName === "A" && el.closest("article")) continue;
    result.push(el);
  }
  return result;
}
