# RSVP Reading Mode — Spec

> **Status: implemented.** One deviation from the plan below: the pill
> polls the `word` file every 60 ms while the drawer is open instead of
> relying on `hs.pathwatcher`. FSEvents coalesces changes with ~300 ms
> latency, which showed up in testing as the drawer running a full word
> behind the audio. The pathwatcher still drives state changes.

## Summary

A toggleable drawer that drops down below the pill while speech is playing,
showing the currently-spoken word, one word at a time, in sync with the
voice. Follow along by eye; glance away without losing your place in audio.

```
┌────────────────────────────────────────────┐
│ ● ▮▮▮▮▮   AUTO   ⏪  ⏸  ⏹  ▾ ✕            │  ← existing pill row
├────────────────────────────────────────────┤
│                                            │
│                 synthesis                  │  ← drawer: current word,
│                                            │     large, centered
└────────────────────────────────────────────┘
```

## UX

- **Toggle**: a small `▾` button on the pill row (left of `✕`). Clicking it
  (or a future hotkey) turns RSVP mode on/off; the choice persists across
  restarts (`hs.settings`, key `tttRsvpOn`).
- **Drawer behavior**:
  - Visible only when RSVP is on **and** state is `playing` or `paused` —
    it drops down when speech starts and retracts when it ends. All other
    states keep the compact single-row pill.
  - Pill height animates 36 → ~92 px, extending **downward** so the
    control row never moves under the cursor.
  - The word renders centered, ~26 pt, white. Words longer than ~12 chars
    shrink to fit rather than clip.
  - **Paused**: the current word stays visible, dimmed to 50%.
  - **Rollback (⏪)**: the word jumps back with the audio automatically —
    the display always derives from the playback cursor.
- Dragging, the ✕ hide button, and layout compaction all behave as today;
  the drawer is part of the same canvas and moves with it.

## Timing model (daemon)

Kokoro's ONNX build returns audio with no word timestamps, so timings are
**estimated within each chunk and hard-resynced at every chunk boundary**
(sentence-ish granularity), keeping error ~±0.3 s and non-accumulating.

1. Synthesis already knows each chunk's exact sample span in the buffer
   (`[chunk_start, chunk_end]`, including the inter-chunk gap).
2. Split the chunk text into words. Weight each word by a cheap duration
   heuristic: `weight = max(1, vowel_groups(word)) + 0.4 if word ends in
   punctuation else 0`.
3. Distribute the chunk's samples across words proportionally to weight,
   producing a timeline of `(sample_start, word)` entries appended under
   the existing lock.

## Publishing (daemon → pill)

- A lightweight publisher thread runs only while a say-request is active:
  every 80 ms it maps the playback cursor into the timeline (binary
  search); when the current word changes (~3×/s at speech pace) it writes
  the word to a new `word` file (atomic tmp+rename, same directory).
- The pill's existing `hs.pathwatcher` already watches that directory;
  a `word` change updates only the drawer's text element — no re-layout.
- The audio callback is untouched: timing is read-only observation of
  `cursor`, so this cannot reintroduce glitches.
- On stop/new-say the timeline is cleared and the `word` file emptied.

## Edge cases

- **Mid-read replacement** (new say/hotkey): generation bump clears the
  timeline; the drawer blanks until the new speech starts.
- **Ready/auto-read staging**: drawer stays closed during `ready`; opens
  when playback begins.
- **Buffer-dry pauses** (synthesis behind): cursor stalls, so the word
  simply holds — correct behavior for free.
- **speed / voice env changes**: timings derive from actual sample spans,
  so they remain correct at any speed.

## ORP anchor (implemented)

Each word is drawn with one letter highlighted in red and **pinned to a
fixed x position**, so the eye fixates on one point instead of tracking
across the drawer. Pivot letter by word length (Spritz convention):
1 char → 1st, 2–5 → 2nd, 6–9 → 3rd, 10–13 → 4th, 14+ → 5th.

The word is rendered as an `hs.styledtext` with a per-character colour
range, and positioned by measuring the prefix so the anchor's centre lands
exactly on the fixation point; faint tick marks above and below reinforce
it. Long words shrink only as far as needed to fit around that fixed
anchor (floor 12 pt).

## Non-goals (v1)

- Karaoke-perfect alignment (would require the PyTorch pipeline's token
  timestamps and a ~2 GB torch dependency).
- Phrase/caption context mode with highlighted word (possible follow-up;
  same timing machinery).

## Implementation plan

| Step | Where | Est. size |
|---|---|---|
| Word timeline + weights during synthesis | `daemon.py` | ~35 lines |
| Publisher thread + word file | `daemon.py` | ~25 lines |
| `▾` toggle button + persisted setting | `talk_talk_talk.lua` | ~15 lines |
| Drawer element, expand/retract, word watcher | `talk_talk_talk.lua` | ~55 lines |
| Font-shrink for long words, paused dimming | `talk_talk_talk.lua` | ~10 lines |
| Test: stage → play → verify word file cadence; synthetic click on ▾ | — | — |

No changes to `ktts`, hooks, or the audio callback.
