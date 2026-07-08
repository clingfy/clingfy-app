# Claymorphism UI Guidelines

Status: **Adopted — reference guide for the desktop redesign**
Audience: contributors styling Flutter UI (`lib/ui`, `lib/app`)
Companion: [architecture.md](architecture.md) · [development.md](development.md) · [../CONTRIBUTING.md](../CONTRIBUTING.md)

This is the design guide for bringing Clingfy's **claymorphism** look to the desktop app. It defines the
visual language (color, shadow, radius, type, motion) and — importantly — how to translate it into
**Flutter** on top of the token system we already have. It changes no code on its own; it's the
contract the redesign follows.

> The current app UI is **flat with hairline borders** (small radii, `elevation: 0`, whisper shadows).
> Claymorphism is the opposite: soft, inflated, matte-clay surfaces. Adopting it is a deliberate,
> incremental restyle of shared widgets — not a rewrite.

---

## 1. What "claymorphism" means here

Everything raised looks like it was **pressed out of soft matte clay**: big rounded corners, chunky
friendly controls, generous whitespace, and a signature soft shadow that gives each surface a puffy,
tactile curvature. It is a saturated, high-craft look with **two first-class themes** (light clay and
dark clay) — not a washed-out pastel style, and not flat Material.

**The ten principles**

1. **Soft, puffy, matte surfaces.** Raised elements read as inflated clay — big radii, chunky controls, air around them.
2. **The signature is a layered shadow on every raised surface:** a soft outer **drop**, an inner **top highlight**, and an inner **bottom shade**. That triad is what sells the "clay" read — apply it consistently.
3. **Spend boldness in exactly one place per screen** (a hero, or a single featured element). Everything else stays quiet and low-contrast.
4. **Both themes are first-class.** Never design for only light or only dark.
5. **Theme follows the OS by default,** is user-togglable, and the choice persists. (Already true in this app — see §6.)
6. **Shadows are per-theme tokens carrying the full value,** not one recipe with swapped colors. The inner top highlight is a strong near-white in light but only a faint light-rim in dark — **structurally different, not recolorable**.
7. **A purple brand gradient anchors the system** across both themes; cyan and coral are supporting accents.
8. **Inputs and wells use the inverse (concave) treatment** so they read pressed-*in*, contrasting with raised clay.
9. **One intentional dark surface may appear inside the light theme** as a focal accent band; it deepens in dark mode.
10. **Respect reduced-motion.** All theme cross-fades and springy interactions are gated behind the platform "reduce motion" setting.

---

## 2. Color

Purple is the anchor (a `#9A6BF0 → #7C4AD8` gradient); cyan and coral are supporting accents. The
single brand seed already in the app is `Color(0xFF8957E5)`.

**Shared accents (both themes)**

| Role | Value |
|---|---|
| Brand gradient (top → bottom) | `#9A6BF0` → `#7C4AD8` |
| Brand seed / links | `#8957E5` |
| Accent cyan (ramp) | `#5FE0F0` / `#38D2E6` / `#2CC4D8` / `#25B5C8` |
| Ink on cyan | `#0B3A42` |
| Accent coral (top → bottom) | `#FF7A8C` → `#F44B63` |
| Star / gold | `#F5B301` |

**Light theme**

| Role | Value |
|---|---|
| Background (gradient) | `#F2EFFA` → `#E9E3F8` |
| Surface / card | `#FFFFFF` |
| Primary text (ink) | `#241C3F` |
| Muted / secondary text | `#6B6876` — desaturated gray (**not** brand-tinted) |
| Brand text | `#8957E5` |
| Accent text (eyebrows) | `#7C4AD8` |
| Divider / hairline | `rgba(137,87,229,0.12)` |
| Focal dark band (the one dark surface) | `linear-gradient(150deg,#2E2352,#3D2C6E,#4A3585)` |

**Dark theme**

| Role | Value |
|---|---|
| Background (gradient) | `#0C0A18` → `#141026` |
| Surface / card | `#1C1832` (deep desaturated indigo) |
| Primary text (ink) | `#F1EDFB` |
| Muted / secondary text | `#A9A5B6` — desaturated gray (**not** purple-tinted) |
| Brand text | `#A37AF0` (lightened for contrast) |
| Accent text | `#C7A6FF` |
| Divider / hairline | `rgba(255,255,255,0.06)` |
| Overlay scrim | `rgba(10,8,20,0.6)` + blur |

> **Desaturated muted text is a hard rule.** Secondary text is neutral gray in both themes. Do not
> derive it from the brand purple/navy. The app already honors this (`textSecondary` ≈ `#6F6685` /
> `#BAB7C8`) — keep it that way.

---

## 3. The clay shadow recipe (the important part)

Every raised surface gets **three layers**:

1. a soft **outer drop** (brand-tinted in light; deep black + a soft purple ambient glow in dark),
2. an inner **top highlight** (near-white in light; a faint light-rim in dark),
3. an inner **bottom shade** (brand-tinted in light; black in dark).

Canonical values (web reference — scale down for desktop density, see §5):

| Token | Light | Dark |
|---|---|---|
| **card** (default raised) | `0 30px 60px -18px rgba(80,50,160,.35)`, `inset 0 3px 6px rgba(255,255,255,.95)`, `inset 0 -8px 16px rgba(137,87,229,.10)` | `0 34px 70px -20px rgba(0,0,0,.85)`, `0 0 60px -20px rgba(137,87,229,.35)`, `inset 0 3px 5px rgba(255,255,255,.12)`, `inset 0 -9px 18px rgba(0,0,0,.5)` |
| **small** (pills/chips/tiles) | `0 8px 18px -8px rgba(60,40,120,.25)`, `inset 0 2px 4px rgba(255,255,255,.9)`, `inset 0 -3px 6px rgba(137,87,229,.10)` | `0 12px 24px -10px rgba(0,0,0,.65)`, `inset 0 2px 3px rgba(255,255,255,.10)`, `inset 0 -4px 8px rgba(0,0,0,.45)` |
| **button** (gradient CTA) | `0 16px 30px -10px rgba(137,87,229,.55)`, `inset 0 3px 5px rgba(255,255,255,.4)`, `inset 0 -5px 10px rgba(0,0,0,.22)` | `0 18px 34px -12px rgba(124,74,216,.6)`, `0 8px 16px -8px rgba(0,0,0,.55)`, `inset 0 3px 5px rgba(255,255,255,.38)`, `inset 0 -7px 13px rgba(0,0,0,.32)` |
| **featured** (one per screen) | `0 44px 80px -20px rgba(80,50,160,.5)`, `inset 0 4px 8px rgba(255,255,255,1)`, `inset 0 -10px 22px rgba(137,87,229,.16)` | `0 42px 80px -22px rgba(0,0,0,.9)`, `0 0 70px -18px rgba(137,87,229,.5)`, `inset 0 3px 5px rgba(255,255,255,.14)`, `inset 0 -9px 18px rgba(0,0,0,.5)` |
| **field-inset** (concave inputs) | `inset 0 2px 4px rgba(80,50,160,.12)`, `inset 0 -1px 2px rgba(255,255,255,.8)` | `inset 0 4px 8px rgba(0,0,0,.5)`, `inset 0 -1px 2px rgba(255,255,255,.05)` |

Note the dark card is **not** the light card recolored: the top highlight drops from `.95` → `.12`
and a purple ambient glow appears. Store each as its own per-brightness token.

---

## 4. Radius, type, spacing, motion

**Radius** — clay wants larger corners than the current flat UI. Canonical web scale: `sm 20`,
`md 24`, `lg 32`; pills/dots `999`. See §5 for the **desktop-scaled** version.

**Typography** — a rounded **display** face paired with a neutral **body** face:
- Display: **Baloo 2** (rounded, friendly), weights 600/700/800 — headings, buttons, wordmark, eyebrows.
- Body: **Inter**, weights 400–700 — body and UI text.
- Fallback: `system-ui, sans-serif`. Headings use tight negative letter-spacing; eyebrows are 13px, 700, UPPERCASE, positive tracking.
- Both fonts are open-licensed (SIL OFL) and safe to bundle. Add them to `pubspec.yaml` `fonts:` (or `google_fonts`) and wire them into `AppTypographyTokens`.

**Spacing & density** — generous but on a consistent rhythm. The app's `AppSpacingTokens`
(`xs 4 → xxl 24`) already provide the scale; clay mainly asks for **more padding inside surfaces** and
**more air between them**. Always set padding per axis (see Don'ts).

**Motion** — two families, both gated behind reduced-motion:
- **Appearance cross-fade:** animate `color`, `boxShadow`, `border` over ~200ms when the theme changes.
- **Interactive spring:** on press/hover, use an overshoot curve — `Cubic(0.34, 1.56, 0.64, 1)` over ~220ms — for a squishy "clay" feel. Hover lifts a few px (`translateY(-3..-6)`), press sinks (`translateY(2) scale(.97)`), primary buttons grow their drop shadow on hover.

```dart
const clayspring = Cubic(0.34, 1.56, 0.64, 1); // springy overshoot for press/hover
```

---

## 5. Translating web clay → Flutter

Two gotchas make this more than a copy-paste:

### 5a. Flutter `BoxShadow` has **no `inset`**
The outer drop layers map directly to `BoxShadow`; the **inner** highlight/shade layers do **not**.
Reproduce the inflated curvature with a subtle surface **gradient** + a light **rim**:

```dart
// CSS: 0 30px 60px -18px rgba(80,50,160,.35)  →  BoxShadow:
BoxShadow(
  color: const Color(0xFF5032A0).withValues(alpha: 0.35), // rgb(80,50,160)
  offset: const Offset(0, 30),
  blurRadius: 60,
  spreadRadius: -18,
)
// Dark ambient glow  0 0 60px -20px rgba(137,87,229,.35):
BoxShadow(color: const Color(0xFF8957E5).withValues(alpha: 0.35), blurRadius: 60, spreadRadius: -20)
```

For the inset highlight (`inset 0 3px 6px rgba(255,255,255,.95)`) + bottom shade
(`inset 0 -8px 16px rgba(...)`), fake it with a top→bottom `LinearGradient` on the fill (a touch
lighter at the top, a touch darker at the bottom) plus a 1px light top rim. Only reach for an
inset-shadow package if a truly concave well (inputs) needs it — prefer the gradient approach to avoid
a dependency.

### 5b. Use the modern APIs the codebase already uses
- **`Color.withValues(alpha: …)`** — never the deprecated `withOpacity()`.
- Material 3 is on (`useMaterial3: true`); prefer M3 `ColorScheme` roles already mapped in the palette.
- Interactive state uses **`WidgetStateProperty` / `WidgetState`** (not the old `MaterialState*`).

### 5c. Scale magnitudes down for desktop density
The canonical values are tuned for a marketing web page (32px radii, 60px blurs). A dense editor UI
would look wrong at that scale. Adopt the **recipe and proportions**, but pick desktop magnitudes:

| Surface class | Radius | Shadow feel |
|---|---|---|
| Large / floating (dialogs, hero preview card, frameless window shell) | 20–24 | Full soft clay (bigger blur, visible lift) |
| Panels / cards (sidebars, inspector groups) | 14–18 | Medium clay (moderate blur, small offset) |
| Controls (buttons, chips, tiles) | 10–14 | Small clay |
| Pills / dots / toggles | 999 | Small clay |
| Inputs / wells | 10–14 | **Concave** (inset feel), no outer drop |

Reserve the heaviest shadow + largest radius for the single focal element on a screen.

---

## 6. Adopting it in this codebase

The app already has a **central, brightness-aware token system** — extend it, don't fork it.

- **Single source of truth:** `lib/ui/theme/app_theme.dart` → `_ResolvedPalette.forBrightness(Brightness)` resolves every color and builds the `ColorScheme`. Existing `ThemeExtension`s: `AppThemeTokens`, `AppSpacingTokens`, `AppTypographyTokens`, `AppEditorChromeTokens`, consumed via `context.appTokens` / `context.appSpacing` / `context.appTypography` / `context.appEditorChrome`.
- **Tri-platform:** `buildThemeData` (Material), `buildMacosTheme` (macos_ui), `buildFluentTheme` (fluent_ui) all read the same `_ResolvedPalette`. Any clay values must flow through all three, or be applied at the shared widget layer so they render identically regardless of host design system.
- **Theme mode:** `AppPreferencesController` persists `ThemeMode` (defaults to `system`); `PlatformApp` wires `theme`/`darkTheme`/`themeMode`. No new theme-switching plumbing needed.

**Recommended seam**

1. Add **`AppClayTokens extends ThemeExtension<AppClayTokens>`** (new file `lib/ui/theme/app_clay_tokens.dart`) holding, **per brightness**: surface fill + top-highlight + bottom-shade colors, rim color, `List<BoxShadow>` for card/small/button/featured, the concave field spec, and the clay radii.
2. Populate it inside `_ResolvedPalette.forBrightness` (the one place), register it in the Material `extensions:` list, and read the same fields in the mac/fluent builders.
3. Expose `context.appClay` alongside the existing extension getters at the bottom of `app_theme.dart`; re-export from `app_shell_tokens.dart`.
4. Ship a reusable **`ClayContainer` / `ClaySurface`** widget (`lib/ui/platform/widgets/clay_container.dart`) that wraps a `Container`/`DecoratedBox` with the gradient fill + rim + `boxShadow`. Keep raw `Color(0x…)` literals **out** of feature widgets — the codebase already centralizes color, so clay should too.

```dart
// Sketch — the shared surface every clay card/panel builds on.
class ClayContainer extends StatelessWidget {
  const ClayContainer({super.key, required this.child, this.radius, this.padding, this.featured = false});
  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final clay = context.appClay;
    final r = radius ?? clay.radiusMd;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200), // theme cross-fade (respect reduce-motion)
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        gradient: LinearGradient(                       // fakes inset top-highlight → bottom-shade
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [clay.surfaceHighlight, clay.surface, clay.surfaceShade],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border.all(color: clay.rimHighlight, width: 1),
        boxShadow: featured ? clay.featuredShadow : clay.cardShadow, // outer drop(s)/glow
      ),
      child: child,
    );
  }
}
```

**Restyle order (highest leverage first).** Style the shared platform primitives under
`lib/ui/platform/widgets/` — `app_button`, `app_icon_button`, `app_dialog`, `app_section`,
`app_settings_group`, `app_inset_group`, `app_segmented`, `app_slider`, `app_text_field`,
`app_control_box`, `app_pane_header`, `app_inline_notice`, etc. Most of `lib/app` composes these, so
converting them propagates clay app-wide. Then the home shell (`hero_panel`, sidebars, toolbars),
recording/post-processing panels, dialogs, onboarding, and the paywall.

> **Frameless window:** the app draws its own window chrome (`window_manager`), so the **outer shell**
> rounding + shadow is app-drawn — a natural place for the largest clay surface.

---

## 7. Component recipes

| Component | Treatment |
|---|---|
| **Card / panel** | Surface fill + medium clay radius + `card` shadow. The default raised container. |
| **Pill / chip / badge** | Surface fill + `999` radius + `small` shadow; display font, weight 600–700. |
| **Primary button** | Purple gradient (`#9A6BF0→#7C4AD8`), white text, weight 700, medium radius, `button` shadow; hover lifts + grows shadow, press sinks (`translateY(2) scale(.97)`). |
| **Ghost / secondary button** | Surface fill, ink text, same size/motion, softer clay shadow. |
| **Cyan CTA** | Cyan gradient (`#5FE0F0→#2CC4D8`) with teal ink (`#0B3A42`) + cyan-tinted glow — the supporting accent CTA. |
| **Input / URL field** | **Concave**: field fill + `field-inset` shadow (inset only), pill/rounded, muted placeholder. Reads pressed-in. |
| **Icon tile** | Small rounded-square with a two-stop gradient (purple/cyan/coral family) + `small` shadow; holds a 24px icon. |
| **Theme toggle** | Small clay pill showing the icon of the theme you'd switch *to*; keyboard-accessible with a visible focus ring. |
| **Featured element** | The one bold surface per screen: largest radius, `featured` shadow (adds a purple ambient glow in dark), a subtle scale-up. |
| **Modal / overlay** | Scrim `rgba(10,8,20,.6)` + blur; dialog is a clay card with a large radius and an inset content well; closes via ✕, backdrop, and Esc. |
| **Circular accent control** | Round control with an accent gradient and the clay recipe recolored to that accent — the shadow system generalizes to any color and shape. |

Large frames (preview card, dialogs) that contain media should give the inner content area an **inset**
(recessed) treatment, so the media reads as sunk into the raised clay frame.

---

## 8. Do's & Don'ts

**Do**
- Keep muted/secondary text a desaturated neutral gray in both themes.
- Define shadows as **per-brightness tokens** carrying the full value; dark ≠ light recolored.
- Ship both themes together; default to the OS setting.
- Reserve the heaviest shadow, largest radius, and any saturated/dark surface for the **single** focal element per screen.
- Route every clay surface through `ClayContainer` / `AppClayTokens`; keep color literals out of feature widgets.
- Gate animation behind reduced-motion.
- Verify layouts by **measuring** across window sizes, not eyeballing.

**Don't**
- Don't tint secondary text with the brand (no navy/purple body text).
- Don't ship a washed-out "dusk/pastel" variant — this is saturated clay with clear light + dark modes.
- Don't write two-value padding shorthands on layout containers — in Flutter, prefer explicit
  `EdgeInsets.only(...)` / `.symmetric(...)` rather than a bare `EdgeInsets.all` where axes should differ
  (the web analogue `padding: 52px 0` silently zeros an axis).
- Don't hardcode a clay shadow inside one widget — reference the token (light/dark differ structurally).
- Don't make everything shout; quiet surfaces make the one bold element land.
- Don't use `withOpacity()` — use `withValues(alpha:)`.

---

## 9. Scope

This document is guidance for the redesign; it introduces no code by itself. Implement it by extending
`lib/ui/theme/` with `AppClayTokens`, adding `ClayContainer`, and converting the shared `app_*`
primitives first. Keep the light and dark themes in lockstep the whole way.
