import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { permalinkFor } from "../src/shortcode.js";

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

test("finds the permalink from a deeply nested element in a grid thumbnail, past decoy anchors", () => {
  const doc = load("grid-thumb.html");
  const img = doc.querySelector(".deep-entry-image");
  assert.equal(permalinkFor(img), "https://www.instagram.com/p/Q4rR6sS8tT0/");
});

test("finds the permalink from the deeply nested photo on an open post page, past decoy anchors", () => {
  const doc = load("permalink.html");
  // Unlike the Step 2 test (which enters at <article>, depth 0), this enters at the photo
  // itself — five ancestor levels down, behind the avatar, username, two commenter and one
  // hashtag anchor, all of which must be skipped before the real permalink-time anchor.
  const img = doc.querySelector("img");
  assert.equal(permalinkFor(img), "https://www.instagram.com/p/E7gG9hH1iI3/");
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
