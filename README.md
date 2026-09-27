# tiecook2

A small, self-contained recipe manager: **import** recipes into a local
library of plain-text files, **browse** them in a terminal, and **export** a
static website you can put online — no HTML or database knowledge needed.

Built in Free Pascal (FPC 3.2.2). One source compiles natively on Linux and
cross-compiles to Windows.

## Build

```
make            # native binary: ./tiecook2
make win        # Windows binary: tiecook2.exe (win64, no extra toolchain)
make test       # run the unit tests
```

Requires FPC 3.2.2+ with the standard units (`video`, `keyboard`, `mouse`,
`Process`, `IniFiles`).

## Commands

```
tiecook2                                   browse the library (read-only TUI)
tiecook2 list [--library DIR]              list every recipe
tiecook2 search [--library DIR] <words>    search titles/keywords/text
tiecook2 import mealmaster [--library DIR] <file|dir>...
tiecook2 export html [--library DIR] <output-dir>
```

`--library DIR` overrides the library location for one run; otherwise the
value from the config file is used.

### Import

`import mealmaster` reads Meal-Master `.mmf` files (a single file may hold
many recipes) and writes one plain-text file per recipe into the library.
Amounts become fractions (`0.50` → `1/2`), unit codes expand (`ts` → `tsp`),
categories become keywords, and the directions become numbered steps.
Re-importing the same source updates the existing file instead of duplicating
it.

### Export

`export html` regenerates a complete static site from the library: an
`index.html` with a live search box, a personal section and alphabetical
groups, one page per recipe, a shared `style.css`, and copied images. It
writes only into a directory it created (marked with `.tiecook2-site`) and
refuses to overwrite anything else, so it can't clobber an existing site.

## Browse

Run `tiecook2` with no arguments.

**Recipe list**

- Type to search (matches every word against titles, keywords and text),
  Backspace to edit.
- Up/Down/PgUp/PgDn/Home/End to move; the mouse selects and the wheel scrolls.
- Enter (or click the selected recipe) opens it.
- F10 quits.

**Recipe view**

- Up/Down/PgUp/PgDn/Home/End (or the wheel) scroll.
- `o` opens the recipe's source URL, `i` opens its photo, in your default app.
- Backspace (or Left) goes back to the list; `q` or F10 quits.

Non-ASCII characters are transliterated to ASCII for the terminal display
(the console is one byte per cell); the library files and the exported HTML
keep full UTF-8.

## Configuration

On first run tiecook2 writes a config file you can edit:

- Linux: `$XDG_CONFIG_HOME/tiecook2/config.ini` (usually
  `~/.config/tiecook2/config.ini`)
- Windows: `%APPDATA%\tiecook2\config.ini`

Put comments on their own line starting with `;` — the INI reader treats
anything after `key=` (including a trailing `; ...`) as part of the value.

```ini
[library]
; recipe library location (blank = default data dir)
dir=

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
```

Recipe photos: give a recipe an `image:` line naming a file next to it in the
library, or just drop `<slug>.jpg` (or `.jpeg`/`.png`/`.webp`) beside the
recipe file — export picks it up and the browser can open it.

## Project layout

```
tiecook2.pas       entry point / command dispatch
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
