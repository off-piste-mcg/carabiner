import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { selectContainers } from "../src/containers.js";
import { permalinkFor, permalinkFromHref } from "../src/shortcode.js";

// Fix round 1, Finding 1 (Important, DEMONSTRATED by the reviewer against the fixtures
// then in place): the pre-fix selector `article, a[href^='/p/'], a[href^='/reel/']`
// matched BOTH an <article> and the permalink anchor nested inside it, so a feed post
// produced 2 buttons instead of 1.
//
// Fix round 3: all three fixtures are now REAL captured markup (2026-08-13), and they
// exposed a second, bigger bug: Instagram's profile grid prefixes the account handle
// (`/liverpoolfc/p/Db-bJHcjkxw/`), which the old `a[href^='/p/']` prefix selector could
// not match at all — measured 0 containers on a real grid page, meaning the button never
// appeared on any profile page. The counts below are measured against the real fixtures,
// not assumed, and each is explained.

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

test("feed-post.html (real, 1 post): exactly one button, on the <article>, not the timestamp anchor", () => {
  const doc = load("feed-post.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
  assert.equal(permalinkFor(containers[0]), "https://www.instagram.com/p/Db-Xe7jDlkM/");
});

test("permalink.html (real, an open post page): exactly one button, despite 12 comment permalinks for the same post", () => {
  // permalink.html is /p/Db7r40nDcEf/. It contains the handle-prefixed post link
  // (/liverpoolfc/p/Db7r40nDcEf/) PLUS 12 comment permalinks
  // (/p/Db7r40nDcEf/c/<comment-id>/, one per top-level comment) — all 13 anchors resolve
  // to the same post and all 13 sit inside the single <article>, so all 13 are deduped
  // away by the enclosing-<article> rule and only the article itself survives. A fix that
  // matched comment links but forgot the dedup rule would produce 13 buttons here, not 1.
  const doc = load("permalink.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
  assert.equal(permalinkFor(containers[0]), "https://www.instagram.com/p/Db7r40nDcEf/");
});

test("grid-thumb.html (real, a profile grid): exactly twelve buttons — one per distinct post, none duplicated", () => {
  // Measured directly against the fixture, not assumed: 12 <a href> elements, 12
  // distinct wrapper <div>s (one per thumbnail), 12 distinct hrefs, no <article> anywhere
  // on the page (grid view has none), so none of the 12 permalink anchors gets deduped
  // away — each IS its own container. 8 of the 12 are /p/ (photo/carousel) posts and 4
  // are /reel/ posts; there are not 8 "thumbnails" containing 12 links, as an earlier,
  // uncertain reading of this fixture suggested — there are 12 thumbnails, each with
  // exactly one link, verified with a plain querySelectorAll count.
  const doc = load("grid-thumb.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 12);
  for (const el of containers) {
    assert.equal(el.tagName, "A");
    assert.match(permalinkFromHref(el.getAttribute("href")), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
  }
  // All twelve permalinks are distinct posts, not the same post counted twice.
  const links = containers.map((el) => permalinkFromHref(el.getAttribute("href")));
  assert.equal(new Set(links).size, 12);
});

test("an anchor nested inside an <article> is never selected on its own", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/p/C1a2b3c4/">permalink</a></article></body>`
  ).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
});

test("a bare permalink anchor with no enclosing <article> is selected on its own", () => {
  const doc = new JSDOM(
    `<!doctype html><body><a href="/p/C1a2b3c4/">permalink</a></body>`
  ).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "A");
});

test("a handle-prefixed permalink anchor with no enclosing <article> is selected on its own (the profile-grid case)", () => {
  const doc = new JSDOM(
    `<!doctype html><body><a href="/liverpoolfc/p/Db-bJHcjkxw/">post</a></body>`
  ).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "A");
});

test("comment-permalink anchors are recognised as post links but fully deduped away inside an <article>", () => {
  // Isolated, minimal pin for the exact scenario the reviewer flagged as easy to get
  // wrong: a naive fix could match /p/CODE/c/<id>/ (correct — it IS a link to the post)
  // without also applying the enclosing-<article> dedup to it, producing one button per
  // comment instead of one button for the post.
  const doc = new JSDOM(`<!doctype html><body><article>
    <a href="/p/C1a2b3c4/c/17900648991551355/">reply</a>
    <a href="/p/C1a2b3c4/c/17901934029539891/">reply</a>
    <a href="/p/C1a2b3c4/c/17902782894492499/">reply</a>
  </article></body>`).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
});

test("a non-post anchor (profile, hashtag) is never selected as a container", () => {
  const doc = new JSDOM(
    `<!doctype html><body>
       <a href="/liverpoolfc/">profile</a>
       <a href="/explore/tags/mountains/">#mountains</a>
     </body>`
  ).window.document;
  assert.equal(selectContainers(doc).length, 0);
});
