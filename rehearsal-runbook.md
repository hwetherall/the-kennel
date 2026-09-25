# Synthetic dress rehearsal — runbook

For the host (Harry) plus 3–6 guests on their own phones. Roughly 45 minutes.
Runs entirely on the **development branch preview**. Nothing here touches
production.

The point of tonight is not to prove the tests pass — they do. It is to find
what breaks when real people on real phones use this at the same time, and to
build your muscle memory on the console before the night.

## URLs

| | |
|---|---|
| Guests | <https://bk8ptwjs-yw5.insforge.site> |
| Host console | <https://bk8ptwjs-yw5.insforge.site/host> (PIN gate) |
| Projector | <https://bk8ptwjs-yw5.insforge.site/screen> |
| Print backup | <https://bk8ptwjs-yw5.insforge.site/host/print> |

This preview is built from exactly the code that is live in production, so
whatever you find tonight is a real finding.

## Before you start — 5 minutes

1. Open `/host` and enter the PIN.
2. Set the two team names. Use anything — these are placeholders, the real
   finalists aren't known until the prelims.
3. Press **Shuffle digits**, then **Save**. The branch currently has digits in
   natural `0–9` order, which makes the live square trivially predictable.
   Do not skip this — it is also the exact step you'll take on the night.
4. Open `/screen` on a laptop or TV and leave it running.
5. Confirm the grid shows 100 owned squares.

## Send this to your guests

> Join at **https://bk8ptwjs-yw5.insforge.site**, pick any nickname.
>
> When it asks for an email, use one of these to claim squares and bonus Bones —
> one each, first come first served:
>
> `bluey@rehearsal.test` · `banjo@rehearsal.test` · `scout@rehearsal.test`
> `maple@rehearsal.test` · `rusty@rehearsal.test` · `pippa@rehearsal.test`
>
> **At least one person should join with no email at all** — that's the guest
> who bought no squares, and it needs to work just as well.
>
> Then just play. Back a team when a market opens. Try to break it.

`bluey@rehearsal.test` holds **8 squares** — that one should grant bonus Bones
for only 5 of them (1,250 bonus, 2,250 total). Worth checking on a phone.

## The match

48 scoring events across four quarters. Scores are chosen so each siren lands on
a specific square, and so the finish is close.

**Pace:** aim for 30–45 seconds between taps. Where you see ⏱, wait a full two
minutes first — that lets the Next Goal market actually reach its 90-second lock,
which is a path that never gets exercised if you tap quickly.

### Q1 — ends Home 20, Away 16

| # | Tap | Score |
|---|---|---|
| 1 | Home goal | 6–0 |
| 2 | Away behind | 6–1 |
| 3 | Away goal | 6–7 |
| 4 | Home behind | 7–7 |
| 5 ⏱ | Home goal | 13–7 |
| 6 | Away behind | 13–8 |
| 7 | Away behind | 13–9 |
| 8 | Home behind | 14–9 |
| 9 | Home goal | 20–9 |
| 10 ⏱ | Away goal | 20–15 |
| 11 | Away behind | 20–16 |

**Siren.** Winning square is Home last digit `0`, Away last digit `6`.

### Q2 — ends Home 47, Away 37

| # | Tap | Score |
|---|---|---|
| 1 | Away goal | 20–22 |
| 2 | Home goal | 26–22 |
| 3 | Home behind | 27–22 |
| 4 | Away behind | 27–23 |
| 5 ⏱ | Home goal | 33–23 |
| 6 | Away goal | 33–29 |
| 7 | Home behind | 34–29 |
| 8 | Away behind | 34–30 |
| 9 | Home goal | 40–30 |
| 10 | Away goal | 40–36 |
| 11 | Home behind | 41–36 |
| 12 | Away behind | 41–37 |
| 13 ⏱ | Home goal | 47–37 |

> **Deliberate mis-tap.** Somewhere around event 7, tap the *wrong* button on
> purpose, then use **Undo**. Watch what happens on a guest's phone: their
> balance and the pools should reconcile without a refresh, and the Next Goal
> market that got settled by the bad tap should be refunded. This is the single
> most likely thing to happen for real at 1am.

**Siren.** Winning square is `7` / `7` — both digits the same, worth confirming
the board highlights correctly.

### Q3 — ends Home 68, Away 63

| # | Tap | Score |
|---|---|---|
| 1 | Away goal | 47–43 |
| 2 | Away goal | 47–49 |
| 3 | Home goal | 53–49 |
| 4 | Home behind | 54–49 |
| 5 ⏱ | Away behind | 54–50 |
| 6 | Home goal | 60–50 |
| 7 | Away goal | 60–56 |
| 8 | Home behind | 61–56 |
| 9 | Away behind | 61–57 |
| 10 | Home behind | 62–57 |
| 11 ⏱ | Away goal | 62–63 |
| 12 | Home goal | 68–63 |

> **Two things to inject this quarter.**
> - Have one guest put their phone in **airplane mode** for 30 seconds mid-quarter,
>   then bring it back. They should see an offline banner, then reconcile — not a
>   stale screen and not a double-submitted bet.
> - Hit the **global pause** for about a minute. Betting should freeze; scoring
>   and the quarter transition should keep working.

**Siren.** Winning square is `8` / `3`.

### Q4 — ends Home 94, Away 89

| # | Tap | Score |
|---|---|---|
| 1 | Home goal | 74–63 |
| 2 | Away goal | 74–69 |
| 3 | Away behind | 74–70 |
| 4 | Home goal | 80–70 |
| 5 ⏱ | Away goal | 80–76 |
| 6 | Home behind | 81–76 |
| 7 | Away goal | 81–82 |
| 8 | Home goal | 87–82 |
| 9 | Away behind | 87–83 |
| 10 | Home behind | 88–83 |
| 11 ⏱ | Away goal | 88–89 |
| 12 | Home goal | 94–89 |

**Full time.** Home wins by 5. Winning square is `4` / `9`.

## What to watch for

The failure modes this is actually testing, in rough order of how much they'd
hurt on the night:

- **Undo correctness.** After the Q2 mis-tap, does every phone agree with the
  host? Does the refunded market show as refunded rather than as a loss?
- **Realtime lag.** How long after you tap does a guest's phone update? If it
  needs a manual refresh, that is a serious finding.
- **The siren.** Does the winning square appear immediately and unambiguously,
  on phones *and* the projector?
- **Contention.** When several people stake within the same few seconds, does
  anything fail or double-count?
- **Offline.** Does the reconnecting phone reconcile cleanly?
- **Legibility.** Can you read `/screen` from across the room? Can people find
  the stake buttons without being told?
- **Your own console.** Are the four score buttons big enough to hit reliably
  without looking? That matters more than any feature.

## Afterwards

Write down, roughly: what broke, what confused people, what you fumbled on the
console, and anything that needed a refresh. Rough notes are fine — I'll turn
them into fixes.

Then I'll reset the branch to a clean Phase 2 base and start Phase 3.

## Separately — the automated load run

Independent of the human rehearsal, and worth running tonight too:

```sh
node scripts/rehearse-phase-two.mjs --run      # 60 synthetic guests
node scripts/rehearse-phase-two.mjs --cleanup  # if it's interrupted
```

This is the one that previously exposed the platform's 30-connection ceiling.
Run it *before* the humans arrive, not during — it will compete for connections.
