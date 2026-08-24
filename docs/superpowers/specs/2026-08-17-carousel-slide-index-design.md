# The in-page button must grab the slide you are looking at — design

**Date:** 2026-08-17 · **Status:** implemented; **corrected after final code review**
**Branch:** `feat/browser-extension`

> **Corrections applied after final review (2026-08-17).** Two rules below are amended
> in place, each marked where it appears: the precedence rule ("the address bar wins")
> now requires the page to be showing *that same post*, and the `aria-label` read is
> language-neutral rather than English-only. Both were silent-wrong-answer defects, which
> is the class this document exists to eliminate.

## The defect

Found 2026-08-17 by a user test of checklist item 10, not by any test in the repo: on the
Instagram feed, swipe a carousel to slide 2, click the Carabiner button, answer the dialog
with **"This slide"** — and slide **1** lands in `~/Downloads`. The button reports success.
Nothing anywhere says the wrong file was saved.

The cause is one line of omission. `shortcode.js`'s `permalinkFromHref` canonicalises every
match to a bare `https://www.instagram.com/p/CODE/`, deliberately stripping the handle
prefix a profile grid adds. It also drops any slide information, because there never was
any: the href it reads is a link to the *post*, not to a slide. The app then behaves
exactly as documented — gotcha #15: absent `img_index` means slide 1 — so "this slide"
resolves to the first one, always.

This is worse than an ordinary bug in one specific way, which is why it is worth a spec
rather than a quick patch: **the failure is silent and plausible.** A user who swipes to
slide 4 and gets slide 1 sees a green tick, a banner, and a real file. On a post whose
slides look alike, they may not notice at all.

Scope note: the **hotkey** path does not have this bug. It reads the front tab's URL, and
on a permalink page Instagram writes `?img_index=N` into the address bar itself. Only the
extension discards the information.

## Evidence

Measured against the captured real fixtures in `extension/test/fixtures/` — not synthetic
markup, per gotcha #31 — by driving `containers.js`'s own `selectContainers` over each:

| Fixture | Container | `Go to slide` dots inside | `aria-current="step"` inside |
|---|---|---|---|
| `feed-post.html` | `<article>` | 4 | **1** → `"Go to slide 1"` |
| `permalink.html` | `<article>` | 0 | 0 |
| `grid-thumb.html` | 12 × `<a>` | 0 | 0 |

Two things follow. First, Instagram marks the active carousel dot **semantically**, with
`aria-current="step"` on a `<button aria-label="Go to slide N">`, and those dots sit
**inside** the very container the button is already keyed on. The signal we need is in
reach and is an ARIA attribute rather than an obfuscated class name, so it is among the
more durable things Instagram emits.

Second — and this is a gap, stated rather than papered over — **`permalink.html` is not a
carousel.** It contains no dots, no `Next`, no `Previous`. So we have *no captured markup
of a permalink-page carousel*, and this design deliberately does not depend on any
assumption about one (see "Precedence" below). Capturing that fixture is worthwhile
follow-up work; it is not a blocker.

## Decisions

**Resolve the index at click time, never at attach time.** `content.js` closes `url` over
in `makeButton`, and the buttons map (`container -> { host, url, place }`) rebinds only
when `url` changes. Baking a slide index into `url` would therefore destroy and recreate
the button on every swipe — and resolving at attach time would send whatever slide was
showing when the button first appeared. Neither is acceptable; the click handler is the
only place where "which slide is showing" is a question with a current answer.

**The address bar wins over the DOM — but only when the page is showing that same post**
(corrected after final review, 2026-08-17; the original flat rule is below and was wrong).
Where a page URL already names a slide *for this post*, that is the value the app has
always trusted and the value the hotkey path feeds it. Otherwise the DOM answers — which
is every feed post, since a feed URL is just `instagram.com/`. This ordering still means
the missing permalink-carousel fixture cannot hurt us: on a permalink page the URL names
that very post, so the answer comes from `location.search` regardless of what the dots do
or do not do there.

> **Why the flat "the address bar always wins" rule was wrong.** `location.search` is
> page-global; a button belongs to one container. The two diverge for real: opening a post
> modal from the feed or a grid makes Instagram push `/p/A/?img_index=3`, while the
> containers *behind* the modal are not inside `[role=dialog]`, so they keep their buttons,
> and the overlay's z-index draws them over the modal. Clicking one sent post **B** at
> **A**'s slide index — the same silent wrong-file failure this whole design exists to
> remove, reintroduced by the precedence rule itself. On a single (non-carousel) post it
> also flipped the `carabiner` script out of smart mode into slide mode, landing
> `CODE_s1.*` instead of `CODE.*`.
>
> The guard is a string comparison, not a heuristic: the caller resolves the page's own
> path with `permalinkFromHref(location.pathname)` — the same canonicalisation the
> container's permalink went through — and `grabUrlFor` trusts `search` only when the two
> are equal. Unequal, or unresolvable (a feed `/` or a profile `/handle/` path), falls
> through to the container's dots, which are per-container and cannot be confused. The
> parsing stays in the caller so `slideIndex.js` remains import-free.

**Unknown means today's behaviour, silently** (decided by Wisse, 2026-08-17). If a post is
a carousel but no single active dot can be found — Instagram changed the markup — the
extension sends the bare permalink, exactly as it does now, plus a `console.debug`
breadcrumb. Rejected alternatives: plumbing an "index unknown" flag through `GrabServer`
into the shared `carabiner` script so the dialog could relabel "This slide" as "First
slide" (touches the Shortcut's dialog too, for a case that only arises on markup churn);
and grabbing all slides when unknown (never wrong, but overrides an explicit user choice
in the other direction). The fixture tests are what will catch the churn.

## Design

One new pure module, `extension/src/slideIndex.js`, in the same style and with the same
contract as `shortcode.js`: **it must never throw**, and `null` means "no opinion", never
"slide 1".

```
slideIndexFromSearch(search)      -> positive integer | null
slideIndexFromContainer(element)  -> positive integer | null
grabUrlFor(permalink, { search, pagePermalink, container }) -> string
```

- `slideIndexFromSearch` parses `img_index` out of a `location.search`-shaped string.
  Anything that is not a positive integer is `null`.
- `slideIndexFromContainer` queries `button[aria-current="step"]` **within the container**
  and parses the **first integer anywhere** in its `aria-label` (corrected after final
  review: requiring the literal English word `slide` returned `null` on every localized
  Instagram UI — "Ga naar dia 3" — which is a silent revert to the original slide-1 bug
  for those users, and the `console.debug` breadcrumb built to announce the loss was keyed
  on the same English text, so it was blind in exactly that case; it is keyed on
  `button[aria-current]` now). It returns `null` unless **exactly one** dot is active —
  zero means not a carousel or markup churn, and more than one means we do not understand
  the page well enough to answer.
- `grabUrlFor` composes: search first *when `pagePermalink === permalink`*, container
  second, and returns the bare permalink when both decline. It appends `?img_index=N` — the same shape Instagram itself writes,
  and the same shape the app already parses.

  Two details that must not be left to the implementer's judgement. **It appends even when
  N is 1**: "we know it is slide 1" and "we have no idea" are different states, and
  collapsing them would make the one case we can verify indistinguishable from the fallback
  — it also costs nothing, since gotcha #21's probe skip only applies from `img_index` ≥ 2,
  so a `1` behaves exactly as the bare URL does today. And the permalink it receives is
  always the canonical, query-less form produced by `permalinkFromHref`, so composition is
  a plain append with `?`, never a merge into an existing query string.

`content.js`'s click handler becomes
`grabUrlFor(url, { search: location.search, pagePermalink: permalinkFromHref(location.pathname), container })`
and sends the result. Everything else is untouched: the buttons map keeps keying on the
**bare** permalink, so a swipe changes what a click *sends* without changing what the map
*holds*.

Per surface, the resulting behaviour: **feed** reads the dots; **permalink page** reads the
address bar; **profile grid** sends nothing extra (a grid tile shows the cover, so slide 1
is genuinely the right answer); **reel** sends nothing extra (single video).

**No server-side change is needed, and this is measured, not assumed.** `GrabGate` already
accepts a query string: a `POST /grab` carrying
`https://www.instagram.com/p/DSBAavTCpJo/?img_index=1` was accepted and completed a real
grab on 2026-08-17.

## Testing

Against the real fixture, never a hand-written one:

1. `feed-post.html`'s container resolves to **1** (its active dot is slide 1).
2. The same fixture, mutated so slide **3** carries `aria-current="step"`, resolves to 3 —
   this is the test that would have caught the original bug.
3. Zero active dots → `null`. Two active dots → `null`.
4. Grid tiles → `null`; the bare permalink is what gets sent.
5. `?img_index=4` beats a container whose active dot says 1 — **when the page permalink is
   that same post**. A page URL naming a *different* post must not lend its index; the
   container's dots answer instead (added after final review).
5b. A localized label ("Ga naar dia 3") and a "Go to slide 3 of 4" label both read 3; a
   label with no number reads `null`, never 1.
6. Junk in `img_index` (`0`, `-2`, `abc`, absent) → `null`, and nothing throws.
7. The dedup key is unaffected by the slide index — pinning that we did not bake it into
   `url`.
8. A container whose active dot is slide 1 produces `?img_index=1`, not a bare permalink —
   pinning the "known 1 is not the same as unknown" rule above, which is otherwise the
   easiest thing in this design to quietly optimise away.

**Mutation-check the guard, do not trust it** (gotcha #34): revert the click-time
resolution to attach-time and confirm a test actually goes red, rather than assuming it
would.

## Out of scope

The post modal (`[role=dialog]`) carries no button by design (commit 8c59ddc), and Stories
are outside the extension's scope entirely. Neither is affected.

## Follow-up, not blocking

Capture a real **permalink-page carousel** fixture and add it to `extension/test/fixtures/`,
closing the evidence gap noted above. If such a page turns out to render dots, this design
already handles it — the address bar simply answers first.
