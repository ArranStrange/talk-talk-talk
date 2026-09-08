# RSVP Reading Mode — Spec

> **Status: implemented, then revised (2026-09-08).** Two things changed
> from the plan below. Word onsets are no longer estimated: with read-along
> on, each synthesised chunk is run through Parakeet (already resident for
> dictation) and the heuristic timeline is replaced with the recogniser's
> word onsets about 180 ms after the chunk lands. And the word is shown
> ~120 ms before it is heard, after subtracting the audio device's buffer
> — readers track better when the word is already there as the sound
> starts. The pill is a native app now; words arrive via FSEvents in ~12 ms
> with a 100 ms safety poll.

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
2. Split the chunk text into words. Weight each word by vowel groups as a
   syllable proxy, with acronyms counted a beat per letter and digits two
   beats each (so "SFG20" weighs ~7, not 1), plus a pause for trailing
   punctuation. This must stay free: `kokoro.tokenizer.phonemize()` costs
   ~680 ms a call on this stack, and a per-word call put 11 s into the
   synthesis loop for one chunk. Measured against Parakeet on the same
   audio the vowel heuristic is off by a mean of 122 ms and up to half a
   second — which is why step 4 exists.
3. Distribute the chunk's samples across words proportionally to weight,
   producing a timeline of `(sample_start, word)` entries appended under
   the existing lock. A paragraph gap gets a blank entry so the drawer
   empties during the pause. This heuristic timeline is what plays for the
   first ~180 ms of a chunk and is the fallback when alignment fails.
4. **Refinement.** When the say request carries `align` (read-along on),
   the chunk's 24 kHz audio is resampled to 16 kHz and run through Parakeet
   TDT (`dictate.Engine.align_words`). Its subword tokens are merged into
   words and matched to the source words with `difflib.SequenceMatcher` on
   normalised text; equal runs and same-length replacements (a mis-hearing)
   take the recogniser's onset, insertions/deletions leave gaps that are
   interpolated between aligned neighbours. On the test set 98% of words
   matched; the alignment is within a frame (~80 ms). The chunk's entries
   are swapped in place under `tl_lock`; a stale generation or an unmatched
   entry list leaves the heuristic alone.

## Publishing (daemon → pill)

- A lightweight publisher thread runs only while a say-request is active:
  every 40 ms it maps `cursor − device_lag + lead` into the timeline
  (binary search) — `device_lag` is the output buffer PortAudio reports
  (~470 ms here), `lead` is `rsvp_lead_ms` (default 120) — and when the
  word changes (~3×/s at speech pace) writes it to the `word` file
  (atomic tmp+rename, same directory).
- The app's FSEvents stream on that directory delivers the change in
  ~12 ms and redraws only the drawer; a 100 ms poll covers a missed event.
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
