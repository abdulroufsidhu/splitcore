# One app from a folded cover screen to an ultrawide monitor

## Problem

The app is phone-shaped everywhere. Its entire response to window size is
one widget — `PageBody` centres the content column at 560px — so a 3440px
monitor renders a phone with 1440px of empty paper on either side, and an
unfolded foldable renders the same phone twice as far from your thumbs.

Nothing else adapts. Navigation is `Navigator.push` throughout, so two
things can never be on screen at once no matter how much room there is.
Seven modal bottom sheets slide up from the bottom of a 1440p window.
Padding is a hardcoded `20` in every `fromLTRB`, member cards are a fixed
120px, and the home screen's action row is `Positioned` — which overflows
below about 320px, the width of a folded foldable's cover screen.

Wear OS is deliberately **not** in this spec. A watch cannot render a group
ledger; it needs its own reduced screens, round-screen insets and rotary
input. That is a second project, built on the tokens and data seams this
one establishes.

## Breakpoints

Material 3's window size classes, in `lib/layout.dart`:

| class | width | what appears |
|---|---|---|
| `compact` | < 600 | today's app, unchanged |
| `medium` | 600–839 | navigation rail |
| `expanded` | 840–1199 | list pane + detail pane |
| `large` | 1200–1599 | wider panes, larger type |
| `extraLarge` | ≥ 1600 | inspector pane |

Read through `context.windowSize`, backed by `MediaQuery.sizeOf` rather
than `.of` so a keyboard opening does not rebuild the whole shell.

Spacing comes from the same place. `context.gutter` returns 16/20/24/32/32
by class, replacing the hardcoded `20` that every screen repeats — the page
margin that reads as generous on a phone reads as cramped at 1600px.

**Compact is the floor, not the baseline.** Phones must not regress: below
600px the app is what it is today, and the only changes are the ones that
stop it breaking under 360px.

## Shell

`AppShell` becomes `MaterialApp.home`. It owns the selected group and picks
a layout:

- **compact** — today's `HomeScreen`, push navigation intact.
- **medium** — a `NavigationRail` (Groups, Activity, Account) replacing the
  home screen's top icon row, over a single content column.
- **expanded / large** — list pane (360px) beside a detail pane.
- **extraLarge** — plus an inspector pane (320px): balances, members, and
  former members.

### The detail pane is a nested Navigator

The pane holds its own `Navigator`, keyed by the selected group id.

This is what makes the rest cheap. `add_expense`, `settle_up` and
`new_group` keep their existing `Navigator.of(context).push` calls
untouched — those pushes land in the pane instead of over the window, and
back works, because a Navigator is exactly the thing that already does
this. The alternative, a hand-rolled destination type switched over in the
pane, would reimplement a stack, its transitions and its back handling, and
would need every push site rewritten.

`showDialog` and `showModalBottomSheet` already default to
`useRootNavigator: true`, so dialogs still centre over the whole window
rather than over one pane.

Selecting a different group replaces the pane's stack, because the
Navigator is keyed by group id.

### Screens split in two

Each screen that can appear in a pane becomes a route wrapper around a
view: `GroupDetailScreen` (Scaffold, AppBar, back button) around
`GroupDetailView` (content). Compact pushes the wrapper; the pane embeds
the view. The same split applies to add expense, settle up and new group.

The view keeps the state and the test seams, so the existing widget tests
follow it rather than being rewritten.

## Sheets

`showAdaptiveSheet<T>` — a bottom sheet under `compact`, a width-limited
`showDialog` above it. Seven call sites change one line each. Keyboard
inset handling moves inside the helper, since `viewInsets` only matters in
sheet mode.

## Compact floor

Three things break below 360px and are fixed rather than designed around:
the 120px member cards become flexible, the home screen's `Positioned`
action row wraps (icon-only under 360), and `pageTitleStyle`'s fixed 26pt
scales with the size class.

## Foldables

`MediaQuery.displayFeatures` reports the hinge. When a vertical one is
present, the list/detail split snaps to it, so no pane straddles the fold.
This is the difference between an app that survives being unfolded and one
that was laid out for it — and on a trifold, where two hinges exist, it is
the difference between three usable columns and three arbitrary ones.

## Testing

- A unit test for the width → size-class mapping, including both sides of
  every boundary.
- Widget tests at 320, 400, 700, 1000 and 1800 asserting what appears: the
  rail's presence, the number of panes, and sheet versus dialog.
- **The existing suite is pinned to a compact surface.** Flutter's default
  test window is 800×600, which is `medium` under these breakpoints, so
  every one of the 80 existing tests would silently start rendering the
  rail and testing a layout it was never written for. Pinning states what
  each test is actually about instead of letting a breakpoint change
  rewrite it.

## Order

Layout tokens → shell and rail → two-pane and the nested Navigator →
adaptive sheets → inspector pane → compact floor → hinge. Each step lands
on its own and the app stays shippable in between.

No SDK or server change anywhere in this.
