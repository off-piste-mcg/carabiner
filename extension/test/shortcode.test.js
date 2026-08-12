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
