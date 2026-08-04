# Caption font

`NotoSansArabic-SemiBold-caption.ttf` — the face burned-in video captions are
rendered with. 152 KB, SIL Open Font License 1.1 (`OFL.txt`, ships alongside and
must keep shipping alongside).

## Why a font is bundled at all

Caption text is painted in Flutter and composited into the export natively
(`lib/core/captions/caption_rasterizer.dart` →
`macos/Runner/Capture/Export/CaptionOverlayRenderer.swift`). Without a bundled
family, `TextPainter` resolves against whatever the host has, which means:

- the same project exports differently on different Macs and macOS versions, and
- `flutter test` resolves to a stub font that draws **every glyph as a filled
  box**, so caption tests can pass while producing tofu. That happened: a green
  suite described captions that were entirely empty rectangles, and it was only
  caught by burning them into a real recording and looking at the frames.

Burned-in captions are permanent in the exported file, so a wrong or missing
glyph is not something the user can undo.

## Why this specific file

Despite the name, `Noto Sans Arabic` covers **Latin, Romanian and Arabic** in one
file, which matches the three locales the app ships. One file, one family, no
fallback chain to get wrong.

## Rebuilding it

Derived from the upstream variable font. Reproduce with:

```bash
curl -L -o NotoSansArabic-VF.ttf \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/notosansarabic/NotoSansArabic%5Bwdth%2Cwght%5D.ttf"
curl -L -o OFL.txt \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/notosansarabic/OFL.txt"

pip install fonttools brotli

# Pin to the one weight the rasterizer asks for (FontWeight.w600).
python -m fontTools.varLib.instancer NotoSansArabic-VF.ttf wght=600 wdth=100 \
  -o instanced.ttf

python -m fontTools.subset instanced.ttf \
  --output-file=NotoSansArabic-SemiBold-caption.ttf \
  --unicodes="U+0020-007E,U+00A0-00FF,U+0100-017F,U+0218-021B,U+0300-036F,\
U+02BB-02BC,U+2010-2015,U+2018-201F,U+2020-2022,U+2026,U+2030,U+2039-203A,\
U+20AC,U+2122,U+0600-06FF,U+0750-077F,U+08A0-08FF,U+FB50-FDFF,U+FE70-FEFF,\
U+200C-200F,U+061C,U+2066-2069" \
  --layout-features='*' --drop-tables+=DSIG --name-IDs='*'
```

**Two flags are load-bearing. A naive subset gets both wrong and the failure is
silent:**

- `--layout-features='*'` — the default feature set drops Arabic joining, so
  letters render in isolated forms instead of connecting. It still *looks* like
  text, so it is easy to miss.
- `U+0300-036F` (combining marks) — Noto Sans Arabic has no precomposed `Ț`/`ț`
  (U+0162/0163); it composes them from `T` + combining cedilla. Omit this block
  and exactly those two Romanian characters become tofu while everything else
  looks correct.

## Licence

OFL 1.1 permits bundling in a paid, closed-source application: clause 2 allows
the font to be *"bundled, redistributed and/or sold with any software"* provided
the copyright notice and licence ship with it. The restriction is on selling the
font **by itself**, which is not what this is.

Upstream declares **no Reserved Font Name** (the single occurrence of that phrase
in `OFL.txt` is the definitions section), so this subset — legally a Modified
Version — may keep the Noto name.

`OFL.txt` must remain next to the font and must remain listed in `pubspec.yaml`'s
`assets:` block, which is the only reason `assets/fonts/` appears there; the
`fonts:` block alone would ship the `.ttf` without the licence.

## Verification

`test/core/captions/caption_rasterizer_test.dart` asserts two things about this
file at test time, and both must keep passing:

1. **Real glyphs** — `iiiiiiii` and `WWWWWWWW` must have clearly different
   advance widths. A stub box font gives them identical widths.
2. **Real shaping** — `ببب` must be narrower than three isolated `ب`. Arabic
   joining contracts the run; no contraction means joining is not happening and
   captions will export in isolated forms.

The second is the one that matters. Coverage without shaping still renders
Arabic wrongly, and only a ratio test catches it.
