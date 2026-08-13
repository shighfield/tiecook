# tiecook

A small Free Vision TUI for browsing and searching recipes on a self-hosted
Tandoor Recipes instance. Read-only: search, view a recipe's ingredients and
steps. No editing, meal planning, or shopping list actions.

Built on FPC's Free Vision (Turbo Vision) toolkit, so it runs natively on
both Linux and Windows from the same source.

## Build

```
make
```

Requires FPC 3.2.2+ with the `fv` (Free Vision), `fphttpclient`, `fpjson`,
and `opensslsockets` units available (all part of a standard Free Pascal
install).

### Cross-compiling for Windows

```
make windows
```

Requires `mingw-w64-binutils`, `mingw-w64-crt`, `mingw-w64-gcc`, and
`mingw-w64-openssl-1.1` (the last is AUR) in addition to FPC. Produces
`tiecook.exe` plus three DLLs it needs alongside it at runtime, copied
automatically from the mingw-w64 sysroot:

```
tiecook.exe
libssl-1_1-x64.dll
libcrypto-1_1-x64.dll
libssp-0.dll
```

FPC 3.2.2's bundled `openssl.pas` looks specifically for OpenSSL **1.1**
naming (`libssl-1_1-x64.dll`) on win64, not 3.x (`libssl-3-x64.dll`) — hence
the `-1.1` package. `libssp-0.dll` is a MinGW runtime dependency of the
other two, not a Windows system DLL, and must ship alongside them too.
Copy all four files together to the Windows machine.

### Building a Windows installer

```
make installer
```

Requires `nsis` (AUR) in addition to the Windows cross-compile
prerequisites above. Produces `tiecook-setup.exe`, a per-user installer
(no admin rights needed) that installs to `%LOCALAPPDATA%\Programs\tiecook`,
seeds `%APPDATA%\tiecook\config` from `config.example` on first install
(without overwriting an existing config on upgrade), and adds a
`tiecook` Start Menu folder with shortcuts to launch the app, open the
config file directly in Notepad for editing, and uninstall.

## Configure

Copy `config.example` to `~/.config/tiecook/config` (or
`$XDG_CONFIG_HOME/tiecook/config` on Linux; `%APPDATA%\tiecook\config` on
Windows) and fill in your own values:

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
ufv.pas        -- Free Vision TUI: search/list screen, detail window, event handling
Makefile       -- build (native, Windows cross-compile, Windows installer)
config.example -- template for ~/.config/tiecook/config
installer.nsi  -- NSIS script for the Windows installer
```

## Run

```
./tiecook
```

Keybindings:
- Search box: type to edit, `Enter` to search.
- `Tab`/`Shift-Tab`: switch focus between the search box and the result list.
- List: `Up`/`Down` select, `Enter` (or `Space`) opens the selected recipe,
  `N`/`P` next or previous page of results.
- Detail window: `Up`/`Down` scroll, `Esc` closes back to the list.
- `Alt-X`: quit.
