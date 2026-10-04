# tiecook

A small, self-contained recipe manager: **import** recipes into a local
library of plain-text files, **browse** them in a terminal, and **export** a
static website you can put online — no HTML or database knowledge needed.

Built in Free Pascal (FPC 3.2.2). One source compiles natively on Linux and
cross-compiles to Windows.

## Download

Prebuilt binaries are on the
[latest release](https://github.com/shighfield/tiecook/releases/latest):

- **Windows:** `tiecook-setup.exe` (installer).
- **Linux:** `tiecook-x86_64.AppImage` — `chmod +x` it and run it from a
  terminal (it's a terminal app); OpenSSL is bundled so Tandoor import works.

Or build from source (below).

## Build

```
make            # native binary: ./tiecook
make win        # Windows binary: tiecook.exe + OpenSSL DLLs
make installer  # Windows installer: tiecook-setup.exe (needs makensis)
make appimage   # Linux AppImage: tiecook-x86_64.AppImage (needs appimagetool)
make test       # run the unit tests
```

Requires FPC 3.2.2+ with the standard units (`video`, `keyboard`, `mouse`,
`Process`, `IniFiles`, `fphttpclient`, `opensslsockets`, `fpjson`).

The Tandoor importer links OpenSSL, so the native build needs OpenSSL
installed, and `make win` copies three OpenSSL 1.1 DLLs
(`libssl-1_1-x64.dll`, `libcrypto-1_1-x64.dll`, `libssp-0.dll`) beside
`tiecook.exe` — ship all four files together. Those DLLs come from a
mingw-w64 OpenSSL 1.1 package; adjust `MINGW_SYSROOT` in the Makefile if
yours lives elsewhere.

## Commands

```
tiecook                                   browse, edit and delete recipes (TUI)
tiecook list [--library DIR]              list every recipe
tiecook search [--library DIR] <words>    search titles/keywords/text
tiecook import mealmaster [--library DIR] <file|dir>...
tiecook import tandoor [--library DIR] [--url URL] [--token TOKEN] [--limit N]
tiecook export html [--library DIR] <output-dir>
```

`--library DIR` overrides the library location for one run; otherwise the
value from the config file is used.

### Import

`import mealmaster` reads Meal-Master `.mmf` files (a single file may hold
many recipes) and writes one plain-text file per recipe into the library.
Amounts become fractions (`0.50` → `1/2`), unit codes expand (`ts` → `tsp`),
categories become keywords, and the directions become numbered steps. Trailing
attribution lines (`Recipe by …`, `Recipe FROM: <url>`, `Source: …`) are
dropped from the steps, and any source URL is captured as the recipe's source
link. Re-importing the same source updates the existing file instead of
duplicating it.

`import tandoor` pulls recipes from a [Tandoor](https://tandoor.dev) instance
over its REST API, downloading each recipe's photo. Give it `--url` and
`--token` (a read-scope API token), or set them in the `[tandoor]` section of
the config. `--limit N` imports only the first N recipes (handy for a first
run). Re-importing updates recipes in place by their Tandoor id.

### Export

`export html` regenerates a complete static site from the library: an
`index.html` with a live search box, a personal section and alphabetical
groups, one page per recipe, a shared `style.css`, and copied images. It
writes only into a directory it created (marked with `.tiecook-site`) and
refuses to overwrite anything else, so it can't clobber an existing site.
Each run also prunes pages and images left behind by recipes you've since
deleted or renamed, so re-exporting over a previous site stays clean — you
don't need to empty the directory first.

## Browse

Run `tiecook` with no arguments.

The mouse works throughout: the wheel scrolls, clicking selects (and a second
click opens/edits), and the labels on the bottom status bar are clickable. A
click also dismisses the title screen.

**Recipe list**

- Type to search (matches every word against titles, keywords and text),
  Backspace to edit.
- Up/Down/PgUp/PgDn/Home/End to move; the mouse selects and the wheel scrolls.
- Enter (or click the selected recipe) opens it.
- F4 edits the highlighted recipe, F8 deletes it (with a confirmation).
- F5 imports Meal-Master `.mmf` files: type a file or folder path when prompted.
- F10 quits.

**Recipe view**

- Up/Down/PgUp/PgDn/Home/End (or the wheel) scroll.
- `e` edits the recipe, `d` deletes it (with a confirmation).
- `o` opens the recipe's source URL, `i` opens its photo, in your default app.
- `p` sets or replaces the recipe's photo — type/paste an image path
  (`.jpg/.jpeg/.png/.webp`, `~` is expanded); a blank entry removes it.
- `q`, Esc, or Left goes back to the list; F10 (or Ctrl-Q) quits.

Edit opens a **structured editor**: a form of fields (title, keywords,
servings, time, source, image) and lists (ingredients, steps). The Image
field attaches a photo the same way (copied into the library on save). Move
with Up/Down,
`Enter` edits the current field or item, `a` adds an item after the current
one, `d` deletes it, `[` and `]` move it up or down, **F2 saves**, **F10
cancels** (discarding changes). Click a row to select it, click it again to
edit it, and the wheel scrolls. Longer prose — a step's text or the
description — opens in your editor (config `[editor] command`, else `$VISUAL` /
`$EDITOR` / `nano` / `notepad`) on just that text. When you edit (or add) a
step, **separating the text with a blank line splits it into several numbered
steps** — one per paragraph — so you can break a wall of text into steps right
in your editor. Step numbers are generated automatically for display; you never
type them. The recipe is always written in a clean canonical layout; in the
description, wrapped lines flow together and a blank line makes a paragraph
break.

Delete removes the recipe file and its photo; there is no undo, hence the
confirmation.

Non-ASCII characters are transliterated to ASCII for the terminal display
(the console is one byte per cell); the library files and the exported HTML
keep full UTF-8.

## Configuration

On first run tiecook writes a config file you can edit:

- Linux: `$XDG_CONFIG_HOME/tiecook/config.ini` (usually
  `~/.config/tiecook/config.ini`)
- Windows: `%APPDATA%\tiecook\config.ini`

Put comments on their own line starting with `;` — the INI reader treats
anything after `key=` (including a trailing `; ...`) as part of the value.

```ini
[library]
; recipe library location (blank = default data dir)
dir=

[tandoor]
; used by "import tandoor"; a read-scope API token
url=
token=

[site]
; used by "export html"
title=My Recipes
intro=
footer=
; path to a banner image, copied into the site
header_image=
; path to a page background, copied into the site
background_image=
; recipes with this keyword form a highlighted section
personal_keyword=
; recipes with this keyword are highlighted
favorite_keyword=Favorite

[editor]
; editor for the browser's edit command (blank = $VISUAL / $EDITOR / default)
command=

[ui]
; show the ASCII-art title screen on launch
splash=true
```

Recipe photos: give a recipe an `image:` line naming a file next to it in the
library, or just drop `<slug>.jpg` (or `.jpeg`/`.png`/`.webp`) beside the
recipe file — export picks it up and the browser can open it.

## Project layout

```
tiecook.pas       entry point / command dispatch
urecipe.pas        recipe model + plain-text file format
uconfig.pas        config file (INI)
ulibrary.pas       scan / index / search the library
uimp_mealmaster.pas  Meal-Master (.mmf) importer
uexport_html.pas   static-site generator
urender.pas        wrap + recipe-to-display-lines (pure, tested)
uutf8.pas          UTF-8 -> ASCII transliteration for the console
uopen.pas          open a URL/file in the default app
uui.pas            terminal browser (video/keyboard/mouse)
test/              unit tests (make test)
```
