import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { permalinkFor, permalinkFromHref } from "../src/shortcode.js";

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

test("finds the permalink from inside a feed post", () => {
  const doc = load("feed-post.html");
  const img = doc.querySelector("img");
  assert.match(permalinkFor(img), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("finds the permalink from a grid thumbnail", () => {
  const doc = load("grid-thumb.html");
  assert.match(permalinkFor(doc.querySelector("a")), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("finds the permalink on an open post page", () => {
  const doc = load("permalink.html");
  assert.match(permalinkFor(doc.querySelector("article") ?? doc.body),
               /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("returns null rather than throwing when there is no post", () => {
  const doc = new JSDOM("<!doctype html><body><div id=x>nothing here</div></body>").window.document;
  assert.equal(permalinkFor(doc.getElementById("x")), null);
});

test("ignores query strings and trailing junk", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/p/C1a2b3c4/?img_index=3"><img></a></article></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("img")), "https://www.instagram.com/p/C1a2b3c4/");
});

test("does not mistake a profile link for a post link", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/offpiste.mcg/"><img></a></article></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("img")), null);
});

// The six tests above are the brief's and stay as written. The tests below were added in
// review round 1: two of the three fixture tests resolved at depth 0 (the grid-thumb entry
// was the anchor itself, the permalink entry was the article container), so neither forced
// a real climb past a decoy anchor — 6/6 green was not proof the ancestor walk works. These
// enter from a deeply nested descendant, with decoy anchors (profile/hashtag/tagged-account
// links) placed before the real permalink in document order, so a naive "first anchor wins"
// reader would return the decoy instead.
//
// Fix round 3: all three fixtures were replaced with REAL captured markup (2026-08-13),
// which retargeted the two tests below onto real elements/shortcodes instead of the old
// synthetic fixture's `.deep-entry-image` and made-up codes (that class no longer exists
// in the real grid markup, and the two "past decoy anchors" tests failed outright once the
// fixtures changed — not from a code bug, but from asserting a shortcode that no longer
// exists). The property under test — enter from a real nested descendant, climb past real
// decoy anchors, land on the real permalink — is unchanged and, on the real markup, is
// tested against MORE decoys than the synthetic fixtures had, not fewer.

test("finds the permalink from a deeply nested image inside a real profile-grid thumbnail", () => {
  const doc = load("grid-thumb.html");
  // grid-thumb.html is now REAL captured markup: each thumbnail nests its <img> two DIV
  // levels below the permalink <a> itself (a[href] > div._aagu > div._aagv > img), so
  // this still proves the ancestor walk works from a real descendant, not just an exact
  // match at depth 0. The LAST thumbnail, not the first, rules out a walk that only
  // happens to work because it started at the very first node in the document.
  const imgs = doc.querySelectorAll("img");
  const lastImg = imgs[imgs.length - 1];
  assert.equal(permalinkFor(lastImg), "https://www.instagram.com/p/Db7r40nDcEf/");
});

test("finds the permalink from the deeply nested photo on an open post page, past real decoy anchors", () => {
  const doc = load("permalink.html");
  // permalink.html is now REAL captured markup for /p/Db7r40nDcEf/. The post photo sits
  // 8 ancestor levels below <article>, and in document order it is preceded by two
  // profile-picture links and a commenter's profile link before any post-shaped href
  // appears at all — real decoys, more of them and less convenient than the synthetic
  // fixture's, since this page also contains 12 comment permalinks
  // (/p/Db7r40nDcEf/c/<id>/) that a coarser implementation could latch onto instead of
  // (or in addition to) the real post link. They all resolve to the same canonical URL,
  // so which one is found first doesn't matter here — containers.test.js is what pins
  // that finding one of them must not produce extra buttons.
  const img = doc.querySelector("img");
  assert.equal(permalinkFor(img), "https://www.instagram.com/p/Db7r40nDcEf/");
});

test("does not stop at the first anchor it meets: entry nested inside a decoy anchor, real permalink is a sibling above it", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article>
       <a href="/decoy.account/" class="decoy"><div class="nested"><span id="entry">start here</span></div></a>
       <a href="/p/Z9yY7xX5wW3/">permalink</a>
     </article></body>`
  ).window.document;
  // The entry element's nearest anchor ANCESTOR is the decoy — a reader that grabs the
  // first anchor it climbs into, instead of checking every anchor at that level and
  // continuing to climb when none match, would stop there and return null or the decoy.
  assert.equal(permalinkFor(doc.getElementById("entry")), "https://www.instagram.com/p/Z9yY7xX5wW3/");
});

// Fix round 3: Instagram's profile grid prefixes the account handle
// (`/liverpoolfc/p/Db-bJHcjkxw/`) where the home feed uses the bare form
// (`/p/Db-Xe7jDlkM/`) — measured from real captured pages. The old pattern was anchored
// at the path start and matched NEITHER the handle-prefixed form NOR (by construction) a
// handle that happened to share letters with "p"/"reel"/"reels"/"tv". These tests pin
// both shapes directly, independent of the fixture files, so the regex itself — not just
// its behaviour on today's two captured pages — is under test.

test("accepts the bare permalink shape used on the home feed", () => {
  const doc = new JSDOM(`<!doctype html><body><a href="/p/Db-Xe7jDlkM/">post</a></body>`).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/p/Db-Xe7jDlkM/");
});

test("accepts the handle-prefixed permalink shape used on profile grids", () => {
  const doc = new JSDOM(
    `<!doctype html><body><a href="/liverpoolfc/p/Db-bJHcjkxw/">post</a></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/p/Db-bJHcjkxw/");
});

test("accepts the handle-prefixed reel shape too", () => {
  const doc = new JSDOM(
    `<!doctype html><body><a href="/liverpoolfc/reel/Db8wkcJijrj/">reel</a></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/reel/Db8wkcJijrj/");
});

test("a bare /p/CODE/ permalink is never misparsed as handle='p' with nothing left to match", () => {
  const doc = new JSDOM(`<!doctype html><body><a href="/p/C1a2b3c4/">post</a></body>`).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/p/C1a2b3c4/");
});

test("a bare /reel/CODE/ permalink is never misparsed as handle='reel'", () => {
  const doc = new JSDOM(`<!doctype html><body><a href="/reel/C1a2b3c4/">reel</a></body>`).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/reel/C1a2b3c4/");
});

test("a handle that itself starts with a path keyword still resolves to the real post segment, not the handle", () => {
  // Pathological but not impossible: a handle like "reels.official" starts with the
  // literal text "reel". Proves the optional handle group can't accidentally swallow
  // only PART of itself and misalign the match.
  const doc = new JSDOM(
    `<!doctype html><body><a href="/reels.official/p/C1a2b3c4/">post</a></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), "https://www.instagram.com/p/C1a2b3c4/");
});

test("a plain profile link with no post segment at all still returns null", () => {
  const doc = new JSDOM(`<!doctype html><body><a href="/liverpoolfc/">profile</a></body>`).window.document;
  assert.equal(permalinkFor(doc.querySelector("a")), null);
});

// A comment permalink (`/p/CODE/c/<comment-id>/`, found on a real open-post page — 12 of
// them on permalink.html, one per top-level comment) links to the SAME post as the
// article's own permalink. permalinkFromHref must resolve it to that post, ignoring the
// `/c/<id>/` suffix — containers.test.js is what pins that this must NOT also produce 12
// extra buttons; this is the narrower claim that the URL itself parses correctly.
test("a comment permalink resolves to its post, with the /c/<comment-id>/ suffix ignored", () => {
  assert.equal(
    permalinkFromHref("/p/Db7r40nDcEf/c/17900648991551355/"),
    "https://www.instagram.com/p/Db7r40nDcEf/"
  );
});

test("a handle-prefixed comment permalink also resolves to its post", () => {
  assert.equal(
    permalinkFromHref("/liverpoolfc/p/Db7r40nDcEf/c/17900648991551355/"),
    "https://www.instagram.com/p/Db7r40nDcEf/"
  );
});

test("permalinkFromHref returns null for a non-post href, and null/empty input, without throwing", () => {
  assert.equal(permalinkFromHref("/liverpoolfc/"), null);
  assert.equal(permalinkFromHref("/explore/tags/mountains/"), null);
  assert.equal(permalinkFromHref(""), null);
  assert.equal(permalinkFromHref(null), null);
  assert.equal(permalinkFromHref(undefined), null);
});
