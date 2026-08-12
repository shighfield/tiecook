# tiecook

A small ncurses TUI for browsing and searching recipes on a self-hosted
Tandoor Recipes instance. Read-only: search, view a recipe's ingredients and
steps. No editing, meal planning, or shopping list actions.

## Build

```
make
```

Requires FPC 3.2.2+ with the `ncurses`, `fphttpclient`, `fpjson`, and
`opensslsockets` units available (all part of a standard Free Pascal install).

## Configure

Copy `config.example` to `~/.config/tiecook/config` (or
`$XDG_CONFIG_HOME/tiecook/config`) and fill in your own values:

```
mkdir -p ~/.config/tiecook
cp config.example ~/.config/tiecook/config
```

Generate the token in the Tandoor web UI under Settings > API > **+ NEW**.
Give it scope **read** — tokens with only `bookmarklet` or `mealplan` scope
will fail with an HTTP 403 error when tiecook tries to search or fetch a
recipe.

## Project layout

```
tiecook.pas    -- entry point: load config, construct client, run TUI
uconfig.pas    -- config file loading (base URL + token)
umodels.pas    -- plain data records: TRecipeOverview, TRecipeDetail, TStep, TIngredient
uapi.pas       -- TTandoorClient: HTTP + JSON client for the Tandoor REST API
utui.pas       -- ncurses TUI: search/list screen, detail screen, main loop
Makefile       -- build
config.example -- template for ~/.config/tiecook/config
```

## Run

```
./tiecook
```

Keybindings:
- Search box: type to edit, `Enter` to search, `Esc` to cancel back to the
  list (or quit, if no results yet).
- List: `Up`/`Down` select, `Enter` view recipe, `/` edit search, `n`/`p` next
  or previous page of results, `q` quit.
- Detail view: `Up`/`Down` (or `j`/`k`) scroll, `PageUp`/`PageDown` scroll a
  screenful, `q`/`Esc`/`Backspace` back to the list.
