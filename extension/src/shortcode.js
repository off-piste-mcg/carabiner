// Instagram's markup changes without warning, so this is deliberately forgiving: walk up
// looking for a post container, then find the first anchor that looks like a permalink.
// It must NEVER throw — a null return simply means "no button here".
const POST_HREF = /^\/(p|reel|reels|tv)\/([\w-]+)/;

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

function findPostLink(node) {
  if (typeof node.querySelectorAll !== "function") return null;
  const candidates = [];
  if (node.tagName === "A") candidates.push(node);
  candidates.push(...node.querySelectorAll("a[href]"));
  for (const a of candidates) {
    // getAttribute, not .href: jsdom and about:blank resolve relative URLs differently,
    // and the raw attribute is what Instagram actually writes.
    const href = a.getAttribute("href") || "";
    const match = POST_HREF.exec(href);
    if (match) return `https://www.instagram.com/${match[1] === "reels" ? "reel" : match[1]}/${match[2]}/`;
  }
  return null;
}
