# Yaya’s Calendar brand

Everything a page, a screenshot or a pull request needs to look like Yaya’s Calendar: the name, the
colours, the type, the app icon and the mark, and how the icon files are made.

## Name

| Where | Write |
|---|---|
| UI copy, README, release notes, posts | **Yaya’s Calendar**, with a curly apostrophe (U+2019) |
| The app bundle and anything macOS shows as a file name | `Yaya's Calendar.app` (straight apostrophe) |
| File, folder, repo and asset names | `yayas-calendar` (repo `yayas-calendar-mac`, release asset `Yayas-Calendar-macOS-arm64.zip`) |
| Code | `YayasCalendar` (module, types), `yayascalendar` (bundle ids, folders) |

- One word order, always: never "Yayas Calendar", "Yaya Calendar" or "YC" in public copy.
- It works with Google accounts. Say "for Gmail and Google Calendar users", never "Yaya’s Calendar for
  Gmail", and add "Not affiliated with Google" wherever the Google names appear.
- The app talks as "I" and calls the user "you". Personality lives in empty states, onboarding, the
  gallery descriptions, the About card and the README; never in busy rows, errors, sign-in or sending.

## Colour

### App (windows, popover, panels: always dark)

| Token | Hex | Use |
|---|---|---|
| Accent (teal) | `#3CCBB4` | Buttons, the selected state, the mark, links |
| Accent text | `#05201B` | Text on the accent |
| Accent soft | `#3CCBB4` at 16 % | Medallions and chips behind the accent |
| Navy | `#0E1A22` | The icon tile's base, badges |
| Background | `#14232C` → `#0C161D` | Window gradient, top to bottom |
| Text | `#E9F4F1` | Primary text; 64 % for secondary, 40 % for tertiary |
| Paper | `#F8F5F0` | Light surfaces (mail sheet, the Light widget look) |
| Good | `#6BB857` | Healthy, sent, joined |
| Warn | `#D99E47` | Needs attention, retrying |
| Bad | `#E36166` | Failed, declined, disconnected |

### Widgets (each widget picks Light or Dark)

| Token | Light | Dark |
|---|---|---|
| Background | `#FFFFFF` → `#F8F5F0` | `#15252E` → `#0C171E` |
| Text | `#1D1B20` (secondary `#6E6974`, tertiary `#A7A2AC`) | `#EEF5F3` (64 %, 40 %) |
| Accent | `#14937F` (the teal, deep enough for white) | `#3CCBB4` |
| On accent | white | `#05201B` |

When macOS draws a widget accented or vibrant, the accent becomes the text colour (the system keeps
only luminance), so nothing may depend on the teal being teal.

### Account swatches

Accounts get these in order. They are muted on purpose and never the accent:

`#8FB4C4` `#B8A99A` `#C9A3E6` `#E0A35C` `#E07A80` `#8DBA74` `#7F96E8` `#D2A6C6`

The fictional cast that fills the gallery, the samples, the tests and the screenshots (the Moonfield
desk, every address on a reserved `.example` domain) uses the last four:

| Key | Calendar | Swatch |
|---|---|---|
| `orb` | Orbital Pickle Co. | `#8DBA74` |
| `cmt` | The Quiet Comets | `#7F96E8` |
| `fam` | Moonfield Family | `#E07A80` |
| `home` | Personal (no badge) | `#D2A6C6` |

## Type

- The app: SF Pro Rounded (`AppTheme.font`), heavy for the name and section titles.
- Widgets: System, Rounded or Serif (New York), chosen per widget, at three text sizes (92 %, 100 %, 114 %).
- The menu bar title: the system menu bar font, nothing custom.
- Docs and the README: plain GitHub Markdown, no web fonts.

## The app icon

A cartoon tear-off calendar page with teal rings and a teal binding, its corner curling back into a
glowing teal portal, an envelope flying out: one desk for every calendar and inbox. It sits on a navy
night-sky tile with a few stars and twinkles.

- The tile follows Apple's macOS grid: 824 px on a 1024 px canvas, corner radius 185, drop shadow.
- At 64 px and up the whole scene shows. At 16 and 32 px the icon crops to the page and its portal, so
  the rings, the band and the portal still read.
- Keep a clear space of at least one eighth of the icon's size around it. Never put text, a badge or
  another icon on it, never recolour it, never crop the tile.
- Smallest size: 16 px (Finder lists). The README shows `docs/assets/icon.png` at 120 px.

## The mark

The icon reduced to one path: a calendar page with two ring stubs, its bottom corner curled back over
the portal dot. It is drawn in code (`Sources/Shared/Widgets/BrandMark.swift`, a SwiftUI `Shape` over
`BrandMarkGeometry.path`), so the menu bar, the app and the widgets draw the same shape and no widget
reads a file to show it.

| Where | Size | Colour |
|---|---|---|
| Menu bar | 20 × 15 pt canvas, the glyph 16 × 14 pt (larger status images close the menu on macOS 27) | Template: black, tinted by macOS |
| App sidebar, beside the name | 16 × 14 pt | Accent |
| Widget headers, Large and Extra Large | 12 pt wide, at the far left, the header's own gap (4 to 6 pt) before the title | Accent |
| Widget whole-card states (setup, no accounts, custom slot not set up) | 18 pt (Small) or 24 pt in the 36 / 48 pt accent-soft medallion; at most 28 pt with Large text | Accent |
| Day widget, empty day (Large and up) | 18 pt in a 36 pt medallion | Accent |
| Inbox zero | 20 pt | Accent |

- One colour, always, filled. No outline version, no gradient, no account colour, no rotation, no
  stretching, no envelope.
- Clear space: one ring stub's height (a seventh of the glyph's height) on every side.
- Minimum size: 12 pt wide. Below that, leave it out.
- In widget headers the mark gives way first: when a long title (a custom slot's name, Large text) needs
  the room, the mark goes and the words stay. It never sits beside the ↻ refresh button, which keeps
  the other end of the header.
- Not in busy rows: agenda lines, day blocks, mail rows and the month grid carry no mark.

## How the icon files are made

The master is `Resources/Brand/AppIcon-Source.png`: the transparent artwork at 1024 px, re-encoded with
no metadata. Everything else is drawn from it and from the mark's path by `Tools/MakeIcons.swift`, with
CoreGraphics, ImageIO and Accelerate only (no Xcode, no ImageMagick):

```sh
Tools/make-icons.sh            # compiles Tools/MakeIcons.swift and runs it from the repo root
Tools/check-public.sh --images Resources/Brand/*.png Resources/Generated/* docs/assets/icon.png
```

| File | What |
|---|---|
| `Resources/Generated/AppIcon.icns` | Every size from 16 to 1024 px (10 images), each one a PNG written by the tool |
| `Resources/Brand/AppIcon-1024.png` | The 1024 px tile, for anything that needs the icon large |
| `docs/assets/icon.png` | The 256 px tile (README header) |
| `Resources/Generated/MenuBarIcon@2x.png` | The mark at 40 × 30 px |
| `Resources/Generated/MenuBarIcon.png` | The 1x mark, placed by hand on the 20 × 15 px grid so its strokes land on whole pixels |
| `Resources/Generated/MenuBarIcon.pdf` | The mark as vector art, 20 × 15 pt |
| `build/icon-previews/` | Review sheets: the icon at 16 to 1024 px on light and dark, the glyph in light and dark menu bars (not committed) |

- The tile: navy `#14232C` at the top to `#0E1A22` at the bottom, a teal glow centred on the portal and
  a soft top sheen; from 64 px also a fixed scatter of 52 stars, five four-point twinkles and a hairline
  edge so the tile separates from dark wallpapers (at 16 and 32 px they would only be noise).
- Every PNG keeps its critical chunks only (no text, time, colour profile or any other ancillary
  chunk); the PDF has no info dictionary and no XMP. The same input always gives byte-identical files.
- Any other image that gets committed (cast logos, screenshots) is re-encoded first with
  `Tools/make-icons.sh --strip <input> <output.png>` and must pass `Tools/check-public.sh --images`.
