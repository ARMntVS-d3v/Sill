# Sill standards

The single source of sizes, fonts, and spacing. A widget does not invent its own —
it takes from here. A number that is not here must not appear in code: first it is
added here with an explanation, then it is used.

## fonts — only `TileFont` (Core/TileTypography.swift)

| role | size | where |
|---|---|---|
| `hero` | 28, medium, rounded | the tile's main number: event time, temperature |
| `heroLarge` | 34, medium, rounded | number in the center of a ring (timer in the large size) |
| `heroSecondary` | 12, medium, rounded | companion to the main number: "until 13:30" |
| `title` | 14, medium | object title: event, track, city; empty state |
| `status` | 12 | status under the title: "happening now", "in 20 min" |
| `row` | 13 | list row |
| `rowValue` | 12 | number in a list row (with `.monospacedDigit()`) |
| `caption` | 11 | secondary: location, artist, "and 4 more" |
| `label` | 11, medium | label in the tile corner (via `TileLabel`, caps + kerning 0.5) |
| `axis` | 10 | axis labels and times along a line — the only thing smaller than 11 |

Font size does **not** depend on tile size. With size, the amount shown changes,
not the type size.

## icons — only `TileIcon` (Core/TileTypography.swift)

| role | size | where |
|---|---|---|
| `badge` | 9, bold | icon in a checkbox, tile close cross, board "+" |
| `glyph` | 13 | icon in a list row, weather in the hourly strip |
| `control` | 14, medium | secondary button: previous and next track |
| `controlPrimary` | 15, semibold | primary button: pause and play |
| `hero` | 22 | large state icon: current weather, note in an empty tile |

Icons in the panel wings — `TileFont.row` (13); that is not a tile.

## spacing and radii inside a tile — only `TileMetrics` (Core/TileTypography.swift)

| role | value | where |
|---|---|---|
| `padding` | 13 | inner padding of tile content |
| `paddingOverArtwork` | 11 | text over artwork — the picture creates its own margin |
| `rowGap` | 8 | step between list rows: calendar, tasks, currencies |
| `blockGap` | 10 | gap before a list block |
| `captionGap` | 6 | between the main number and the caption under it |
| `thumbRadius` | 6 | thumbnail: artwork in the capsule, entry preview, file icon |
| `hitRadius` | 7 | highlight of a rectangular hit zone |
| `floatRadius` | 10 | floating bar over content (clipboard search) |
| `trackHeight` | 3 | fill bar |
| `sideColumn` | 104 | width of the left column in the rectangle |

Deliberate exceptions to `rowGap`: the dense number table in system metrics
(`meterGap` 7, and `meterGapDense` 4 when even that doesn't fit — five metrics with
bars have to fit a 152-pt square) and weather (the hourly strip and days have their
own layout; a time slipping under the notch was already caught as a bug).

How many rows fit is decided by the layout, not by a number picked by hand: where a
list can outgrow the tile, wrap the variants in `ViewThatFits(in: .vertical)` — most
complete first. A fixed row count clips the last row as soon as the locale or the
font changes.

The radius of the tile itself, of cards, and of rows is `theme.cornerRadius`, not a number:
it changes with the theme and with a slider in settings. Your own number here = a tile
that ignores the theme.

## countdown dial — `TileDial` (Core/TileDial.swift)

Sixty ticks around the rim, a thin arc of what's left over them, the number in the
middle. Used by the timer and the pomodoro; anything else that counts down to zero
takes the same one. Its own dial in a widget = a review error: two tiles side by side
drawing the same thing differently read as two programs.

## round buttons inside a tile — only `TileControlMetrics`

| tile size | primary | secondary | gap |
|---|---|---|---|
| square | 32 | 26 | 6 |
| rectangle | 30 | 24 | 10 |
| large | 38 | 32 | 14 |

The secondary is always 6 smaller than the primary. The rule is shared by the player
and the timer: two adjacent tiles with buttons of 30 and 32 read as two different programs.

## grid and tiles (Core/Widget.swift, GridMetrics)

| value | amount |
|---|---|
| unit (square S) | 152 |
| gap between tiles | 12 |
| board grid | 4 × 2 units |
| panel side margins | 22 |
| panel bottom margin | 22 |
| gap between wings and grid | 0 (the air is already inside the wings row) |
| wings height | 38 |
| tile sizes | S 1×1, M 2×1, L 2×2 |

Edit-mode chrome is the one thing allowed outside the cell: the remove button sits
flush with the tile's top edge and its hover ring and the jiggle reach above it, so
the board strip is clipped by a rectangle extended upward by
`TileChromeMetrics.topOverhang` (8). Sideways and below the clip stays tight — that is
what keeps the neighbouring board out of sight while paging.

A tile cannot outgrow its cell: the shell clamps content into a hard
`frame` and clips the excess. If content does not fit, that is a layout error in the widget,
not a reason for the tile to grow. Verify with a snapshot: `kill -USR2` and measure the card edges.

Inner padding of tile content is **13**. Exception: text over artwork —
11 horizontally (the picture creates its own margin).

## hit zones

A 13 pt icon gives a 13 pt hit zone — you can only hit it with the mouse by aiming.
The icon's visible size and its hit zone are different values: draw small, catch large.

| element | visible size | hit zone |
|---|---|---|
| icon in a panel wing (edit, settings, pin, quit) | 13 | 26 × 26 |
| board dot | 7 | 22 × 22, center-to-center step 17 (zones overlap) |
| board dot running off the row edge | 5, then 3 | 22 × 22 — the slot stays full size |

A dot only switches boards, in every mode. Edit mode adds one thing to the row: the
"+" that makes a new board — that is where boards get created. Renaming, reordering
and deleting live in Settings → Boards: in the panel they were invisible, and on a Mac
with a menu bar manager (Bartender, Thaw) the right-click that opened them never
arrived. Deleting stays out of the panel on purpose — it can't be undone by eye, and
it has no business a pixel away from a button used constantly. The clipboard board is
not deleted at all: it comes and goes with its setting.

The row never grows past the width the wing gives it. When there are more boards than
fit, it holds a window of dots and shrinks the ones running off the edge — 7 → 5 → 3,
the iOS page indicator. The window follows the active dot (the dragged one in edit
mode). A row that kept growing pushed the wordmark out and slid the far dots under the
notch, where the click trap window ate them.
| board "+" | 11 | 22 × 22 |
| minus on a tile | circle 18 | 26 × 26 |
| resize corner | circle 20 | 28 × 28 |
| button in a list row (pin, delete) | 9 | 20 × 20 |
| clear button inside an input field | 13 | 20 × 20 |

Hover highlighting is mandatory wherever the zone is larger than the icon: without it,
it is unclear where exactly to aim. Highlight shape — corner radius 7 for rectangular zones,
a circle for round ones, fill `tileHover`.

## player controls

| element | value |
|---|---|
| primary button diameter | S 32, M 30, L 38 |
| gap between buttons | S 6, M 10, L 14 |
| scrubber line height | 3, under the cursor 5 |
| line hit zone | 14 (you cannot hit 3 points with a mouse) |
| line handle | 9 |

## color

- Theme tokens only. A hardcoded color in a widget is a review error.
- The single exception: text and buttons **over artwork** — white and black,
  because the background there is a foreign picture, not a tile. A darkening gradient
  under them is mandatory.
- Color is brought into a tile by data (weather icon, calendar color), not by the theme.
- The accent is rationed: active board dot, links, selection. The accent is not used
  over artwork — white goes there.

## animations

Durations — only from `Core/Motion.swift`. A literal in code instead of a constant =
a review error: the same movement spreads across four numbers, and neighboring
elements respond to one gesture out of step.

| what | constant | duration |
|---|---|---|
| hover | `Motion.hover` | 0.14, easeOut |
| edit mode | `Motion.editing` | 0.18, easeOut |
| filling a bar, ring, arc | `Motion.fill` | 0.3, easeOut |
| data appearing in a tile | `Motion.content` | 0.2, easeOut |
| "Ask" conversation | `Motion.askOpen` | 0.24, easeOut |
| edit-mode jiggle | `Motion.jiggle` | period 0.13, easeInOut back and forth |
| capsule at the notch | `Motion.island` | spring 0.34 / bounce 0.14 |
| capsule content | `Motion.islandContent` | 0.12, easeOut |
| content lags the capsule expansion | `Motion.islandContentDelay` | 0.08 |
| compact row returns after the expanded row fades | `Motion.islandRowReturnDelay` | delay 0.14 |
| content swap inside the message capsule | `Motion.islandSwap` | 0.16 |
| board strip | `Motion.boardStrip` | spring 0.34 / bounce 0 |
| transient feedback signal (shelf overflow border; equals the capsule confirmation hold) | `Motion.signalHold` | 1.6 |

| what | duration |
|---|---|
| hover | 0.12–0.18, easeOut |
| edit mode, board switch | 0.18–0.2, easeOut |
| panel opening | 0.28, easeOut, anchor top |
| live animation at the notch (equalizer) | 12 frames per second |
| board strip (settle and rollback) | spring `Motion.boardStrip`, 0.34, bounce 0 |

The edit-mode jiggle is like the iOS home screen: rocking around the center,
period `Motion.jiggle`, each element with its own phase (a random delay up to one
period — elements rocking in sync would read as a mechanism). Amplitude falls with size:
tile S ±1.2°, M ±0.8°, L ±0.6° — including the neighbor in the strip: edit mode
survives swiping, and a calm incoming page would read as leaving
the mode. Board dots don't move at all — there is nothing to drag them to.
Start and stop — only with an explicit `withAnimation`: a declarative repeatForever
does not stop when state is reset without animations.

Preset and extension chips in the timer stand at their own gap of 5, not the shared
button gap: at a gap of 14 a row of five chips is wider than the tile.

Springs — only where the animation continues a finger's gesture: the board strip and the
capsule at the notch. There, the finger's velocity must carry into the animation, otherwise
on release the movement changes speed with a jump and falls apart into two. Everywhere the
movement starts on its own (hover, edit mode, appearance) — `easeOut` without a spring. There is no bounce-back after dragging — the offset is zeroed instantly.

The capsule at the notch appears and leaves by **width morphing**, not by opacity
with scale: the collapsed state is exactly the notch rectangle, and there it disappears
by itself, black on black. Scale stretches the corner radii and text (rubber instead of
morphing); half-screen opacity reads as a ghost over the menu bar. The content meanwhile
fades over `islandContent` — faster than the capsule moves: a narrow capsule gets
clipped at the notch edges anyway. Width is set hard (`frame(width:)`), not as a minimum:
via `minWidth` the capsule cannot be narrowed, and no retraction happens at all.

A capsule that counts seconds is not polled — the island sleeps until the moment its
number changes (`CountingLabel.nextChange`). The label rounds, so it flips on the
value's own phase, half a second off the wall clock: polling twice a second showed the
digits late and in uneven steps. One wake per visible change, and the expensive source
sweep stays on its own slow cadence.

Everything that moves while the panel is closed is drawn at an explicit frame rate and via `Canvas`.
`TimelineView(.animation)` means the display's refresh rate — on ProMotion that is 120 redraws
per second for four equalizer bars, four times more expensive on the CPU.

## empty states

Only `TilePlaceholder` (Core/TileParts.swift): centered, `TileFont.title`,
muted, with the widget's own icon above (`TileIcon.hero`, muted to 75%).
"No events", "Nothing playing", "All done", "No city selected".

The icon is mandatory: from the text alone it is not always clear whose tile this is. If the
empty state has a meaningful action (pick a city, grant access, retry the request),
the button goes under the text — the tile must remain itself, not turn into a stub.

Exception — an input field: the hint is drawn under the field itself, same size and color
(note, "Ask", clipboard search), otherwise it stands away from the cursor. The shared
component is `TileTextField` (Core/TileParts.swift) — a `TextField`, single- or
multi-line, plus an optional circled cross for clearing at the field's trailing edge
(hit zone `TileControlMetrics.fieldClearHit` 20). `TextEditor` is only for a field
where Return has to break the line (the note): it carries its own 5-pt line inset and
draws the caret a line above the text.

One vocabulary for the whole app: "Loading…", "Nothing found", "No events",
"Nothing playing", "All done", "Clipboard is empty", "No battery". Your own phrasing
of the same meaning is a review error. Technical strings ("helper not built") never
make it into a tile.

An empty-state action has no right to open another application. The "play" button
in empty music was removed for exactly this reason: the command goes to the system, which
launches Apple Music even if the person does not use it.

## what each size shows

One principle for all widgets — otherwise the board reads as a set of different programs:

| size | what is in it |
|---|---|
| square | one main number and one action. Everything else is removed |
| rectangle | the main number plus context: details, controls, upcoming values |
| large | the main thing, history or breakdown, and all actions in full |

Type size **does not change** between sizes — the amount shown changes.
If an element does not fit in the square, it is not shrunk — it disappears.

## active elements inside a tile

Any button, input field, slider, or checkbox inside a widget is marked
`.tileControl()` (Core/TileControls.swift). The shell excludes such zones from
dragging: a tile is dragged by its background, not by a button.

Without the mark the element will keep working, but in edit mode the tile will slide
out from under the finger when they try to use it.

## the notch capsule: who wins

One activity is on screen at a time, and the order lives in `LiveActivity.Priority`
(Core/LiveActivity.swift) — never as a number typed at the call site. Sorted by how
much the person is waiting for it: an answer to what they just did, then a deadline
they are counting on, then what they'd notice anyway. A running countdown outranks
music on purpose — music can be heard, a timer cannot.

## persisted state

Anything stored on disk (widget state, config, cache) decodes by hand, field by
field, with `decodeIfPresent` and a default for every value. Swift's synthesized
decoder does **not** fall back to a property's default when the key is missing — it
throws, and one added field silently wipes every record written by the previous
version. That is how a new `counted` flag emptied the notch of every pomodoro at once.

## check before shipping

```bash
grep -rn "\.font(\.system(" Widgets/ Shell/   # must be empty
grep -rn "minimumScaleFactor" Widgets/         # must be empty: type size does not drift
grep -rn "Color(red:\|Color(\.s\|\.white\|\.black" Widgets/   # only over artwork
```
