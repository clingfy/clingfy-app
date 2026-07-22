# Clingfy Reels Series — 30-second daily features & updates

Content plan for a daily Instagram Reels series: one 30-second video per day,
each explaining a single Clingfy feature or a shipped update.

Source of truth for what may be claimed on camera: [`docs/features.md`](../features.md).

## Ground rules

1. **Only shipped features.** If it isn't ✅ on macOS in `features.md`, it
   doesn't get a reel. Unreleased work on `develop` (echo cancellation,
   separated audio, persistence) waits until it ships in a release.
2. **Update reels follow releases.** A "what's new" reel is cut from
   `CHANGELOG.md` the day a version ships — never before.
3. **Windows content waits for the beta launch.** Once invites go out, the
   Windows arc at the bottom unlocks.
4. **One feature per reel.** If explaining it takes more than 30 seconds, it's
   two reels.

## Production defaults

- **Record Clingfy with Clingfy.** Every reel is itself a Clingfy recording:
  capture the app, cut it with the clip timeline, grade it, export **9:16** —
  and say so when it's relevant. The product is the proof.
- Format: 9:16 vertical (1080×1920+), exported straight from the app's
  aspect-preset + vertical-4K pipeline.
- Hook in the first 2 seconds — a claim or a pain, never "hi guys".
- Captions always on (many viewers watch muted). Cursor highlight ON while
  demoing so taps read on a phone screen.
- Structure every reel: **0–2 s hook → 2–25 s show it live → 25–30 s CTA.**
- CTA rotation: "Free on clingfy.com" / "Star it on GitHub — it's open source" /
  "Follow for tomorrow's feature."

## Episode template

```
E## — <feature>
Hook   : <first line, spoken + on-screen text>
Show   : <what is on screen for the 20 s demo>
CTA    : <closing line>
Status : idea | scripted | filmed | posted <date>
```

---

## Arc 1 — Record anything (week 1)

**E01 — Record your whole screen in 2 clicks**
Hook: "This screen recorder is free and open source."
Show: open Clingfy → pick display → countdown → record → stop → preview appears.
CTA: "clingfy.com — link in bio."

**E02 — Record just one window**
Hook: "Stop cropping your screen recordings."
Show: window mode → pick a browser window → record → clean single-window result.

**E03 — Record a custom area**
Hook: "Only want THIS corner of your screen? Draw it."
Show: area mode → drag a region → record → export exactly that region.

**E04 — Pause and resume**
Hook: "Made a mistake mid-recording? Don't start over."
Show: recording → pause from the floating indicator → resume → one seamless file.

**E05 — The countdown timer**
Hook: "3… 2… 1… never catch yourself mid-scramble again."
Show: enable 3/5/10 s countdown → the full-screen count → recording starts.

**E06 — Clingfy never records itself**
Hook: "Why is the recorder in your recording?"
Show: toggle "exclude app from capture" → Clingfy windows vanish from the output.

**E07 — Recordings are projects, not files**
Hook: "Close the app. Your edit is still there."
Show: record → quit → reopen the `.clingfyproj` → timeline and settings intact.

## Arc 2 — Look pro with the camera bubble (week 2)

**E08 — Add your face in one click**
Hook: "Screen + face = 10× more engaging tutorials."
Show: pick camera → floating bubble appears → record → bubble in the export.

**E09 — Restyle the camera AFTER recording**
Hook: "Recorded your face in the wrong corner? Fix it after."
Show: camera is its own source → drag it to a new corner in post → re-export.

**E10 — Camera shapes**
Hook: "Circle, square, squircle — your face, your call."
Show: cycle shapes + border + shadow on the bubble in the editor.

**E11 — Side-by-side & stacked layouts**
Hook: "Talking-head layout without a video editor."
Show: layout presets: corner → side-by-side → stacked → background.

**E12 — Chroma key (green screen)**
Hook: "Green screen. In a screen recorder. Seriously."
Show: bubble with green background → chroma key on → background gone.

**E13 — Camera intro/outro animations**
Hook: "Make your face POP into the video."
Show: intro pop + outro shrink animations in the export.

## Arc 3 — Motion: cursor & zoom (week 3)

**E14 — Highlight your cursor**
Hook: "Viewers can't follow your tiny cursor. Fix it."
Show: cursor highlight halo on, strength slider, recording where taps read clearly.

**E15 — Your cursor is editable after recording**
Hook: "This cursor isn't in the video. It's data."
Show: same recording exported with cursor at 1× then 3× size.

**E16 — Smart zoom**
Hook: "It zooms where you click. Automatically."
Show: record clicks → automatic zoom suggestions appear on the timeline → export.

**E17 — Follow-cursor zoom**
Hook: "Camera-operator zoom, no camera operator."
Show: zoom segment in follow mode tracking the cursor smoothly.

**E18 — Fixed-target zoom**
Hook: "Point the zoom exactly where the action is."
Show: drag the fixed-target overlay onto a button → zoom hits that spot.

**E19 — The zoom timeline**
Hook: "Add, move, resize zooms like a pro editor."
Show: create a segment from the timeline, drag it, resize it, set 1.5× → 3×.

## Arc 4 — Edit without a video editor (week 4)

**E20 — Cut the boring part**
Hook: "Delete the boring part. Right inside the recorder."
Show: split at playhead → select middle clip → Backspace → smooth playback across the cut.

**E21 — Scissors: Option-click to cut**
Hook: "One keystroke. Clean cut."
Show: Option-click two points on the timeline → dead segment removed.

**E22 — Trim by dragging**
Hook: "Recording ran long? Drag the edge."
Show: drag a clip's end edge to trim the tail → export ends exactly there.

**E23 — Reorder your recording**
Hook: "Recorded the steps in the wrong order? Drag them."
Show: drag a clip to a new slot → preview plays the new order → export matches.

**E24 — Undo everything**
Hook: "Edit fearlessly."
Show: a flurry of splits/deletes → undo undo undo → back to the original.

**E25 — One-click color fix**
Hook: "Washed-out recording? One click."
Show: Auto enhance on a dull recording → before/after slider moment.

**E26 — Manual color grading**
Hook: "Exposure, contrast, saturation, temperature, tint — in a screen recorder."
Show: drag sliders, preview updates live, export matches exactly.

**E27 — What you see is what exports**
Hook: "The preview isn't a preview. It's the export."
Show: cuts + zoom + camera + color all active → export → side-by-side identical.

## Arc 5 — Ship it: canvas & export (week 5)

**E28 — Vertical export for Reels**
Hook: "This reel was exported from the app it's about."
Show: 9:16 preset → recording letterboxed on canvas → export → post it. Meta.

**E29 — Backgrounds that aren't boring**
Hook: "Your recording, floating on a designer background."
Show: padding + corner radius + procedural backgrounds (Waves/Mesh/Glow) + randomize.

**E30 — Export as GIF**
Hook: "Bug reports that developers actually watch."
Show: short recording → GIF export → drop it into a GitHub issue.

**E31 — 4K, 8K, HEVC, H.264 — your pick**
Hook: "Crisp enough for a conference screen."
Show: resolution + codec + bitrate pickers → 4K export.

**E32 — Normalize your audio**
Hook: "Too-quiet mic? One checkbox."
Show: loudness normalize on export → level meters before/after.

**E33 — Storage that cleans itself**
Hook: "Screen recordings eat disks. Clingfy shows you where."
Show: storage dashboard charts → clear cached recordings safely.

## Recurring formats (slot between arcs)

- **"What's new in vX.Y.Z"** — release-day recap, top 3 items from
  `CHANGELOG.md`, 10 s each.
- **"3 features in 30 seconds"** — rapid-fire refresher of three earlier
  episodes.
- **Before/after** — raw recording vs. cut + graded + zoomed export, no
  talking, just captions.
- **Speedrun** — "record → cut → grade → vertical export in 30 seconds,"
  real time, no cuts.
- **Open source angle** — "this entire app's code is public," repo scroll,
  star CTA.

## Locked until the Windows beta launches

- "Clingfy is coming to Windows" teaser (installer → record → export).
- "Same app, both platforms" side-by-side.
- Windows-specific: chroma-key bubble on DirectComposition, crash-safe
  recording notice.

## Tracker

| Ep | Status | Posted | Notes |
|----|--------|--------|-------|
| E01 | idea | | |

(Add a row per episode as it moves: idea → scripted → filmed → posted.)
