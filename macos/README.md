# Notepad++ for macOS

Native Cocoa port of Notepad++, built on Scintilla's Cocoa backend and Lexilla.
Goal: 1:1 behaviour with Windows Notepad++, without modifying upstream sources.

## How the port stays 1:1 with upstream

Nothing under `PowerEditor/`, `scintilla/`, `lexilla/` or `boostregex/` is edited,
so `master` keeps tracking upstream and merges cleanly into `macos`.
Upstream is reused in four ways:

| Reuse | What | Where |
|---|---|---|
| Compiled unchanged | Scintilla (+ Notepad++'s boost::regex engine), Lexilla (+ `LexUser`, `LexSearchResult`), pugixml, uchardet, `EncodingMapper.cpp` | `Makefile` |
| Headers included | `Notepad_plus_msgs.h`, `menuCmdID.h`, `NppConstants.h`, `resource.h`, `*_rc.h` | `src/NppUpstream.h` |
| Extracted at build time | default shortcuts (`winKeyDefs`, `scintKeyDefs`), `menuID2LangType()`, menu command IDs | `tools/gen_upstream.sh` |
| Read at runtime | `Notepad_plus.rc` (main menu), all dialog `.rc` files, `langs.model.xml`, `stylers.model.xml`, themes, localization | `src/NppMenuBuilder.mm`, `src/NppRcDialog.mm`, `src/LangManager.mm` |

`compat/windows.h` is a small Win32 type/constant shim that lets those upstream
headers (and `LexUser.cxx`) compile on macOS.

Key pieces of `src/`:

- `NppMenuBuilder` — builds the menu bar from `Notepad_plus.rc`; every item carries its Notepad++ command ID.
- `NppCommands.mm` — command-ID → handler table (port of `NppCommands.cpp`). Menu items without a handler show disabled until ported.
- `NppRcDialog` — turns any upstream `DIALOGEX` into a Cocoa window/view with the same layout and control IDs; dialogs are driven like Win32 dialog procedures.
- `NppSearchEngine` — port of `FindReplaceDlg`'s search core (`processFindNext`, `processReplace`, `processAll`, `processRange`).
- `NppFindReplaceDlg`, `NppFinder`, `NppIncrementalFind`, `NppFindCharsInRange` — Search dialogs and the Search results panel.

## Settings and session

Settings live in `~/Library/Application Support/Notepad++/` using Notepad++'s own
file formats, so they can be copied to/from a Windows `%APPDATA%\Notepad++`:

- `config.xml` — `GUIConfigs`, `FindHistory`, `History` (recent files). Elements the port
  doesn't use yet are kept untouched when the file is rewritten.
- `session.xml` — open files, caret/scroll position, bookmarks, folds, language, encoding.
- `backup/` — snapshots of unsaved documents ("Enable session snapshot and periodic backup",
  on by default as upstream): on quit nothing is asked; unsaved tabs come back next launch.

One default differs on purpose: new documents use Unix (LF) line endings, Notepad++'s
"OS default" on macOS.

## Build

Needs only the Xcode Command Line Tools.

```bash
cd macos
make            # builds ~/Library/Caches/NotepadPP-build/Notepad++.app
make run        # build and launch
make install    # copy to ~/Applications
```

The build lives outside the source tree because codesign rejects bundles
under `~/Desktop` (Finder extended attributes). Output is a universal
(arm64 + x86_64) binary for macOS 11+.

## Keyboard shortcuts

Notepad++'s own shortcut table is used, with Ctrl → ⌘ and Alt → ⌥.
Exceptions forced by macOS:

- ⌘Q quits; Notepad++'s Ctrl+Q (toggle comment) is ⌘/.
- Ctrl+Tab / Ctrl+Shift+Tab stay on the Control key (⌘Tab belongs to macOS).
- Exit has no Alt+F4; use ⌘Q.
- Where Notepad++ binds several keys to one command, the Ctrl+letter one wins (⌘X/⌘C/⌘V, not Shift+Del/Ctrl+Ins).
- Caret navigation keeps macOS conventions (⌘← line start, ⌥← word left).

## Testing hooks

The app accepts a few command-line flags so changes can be checked without a mouse
(and without screen-recording permission):

```bash
APP=~/Library/Caches/NotepadPP-build/Notepad++.app/Contents/MacOS/Notepad++
$APP --dump-menus                                  # menu tree: + ported, - not yet
$APP --snapshot /tmp/out.png file.cpp --cmd 43001  # run IDM_* commands, render all windows to PNG, quit
$APP file.cpp --find-text foo --find-dlg 1641       # drive the Find dialog by FindReplaceDlg_rc.h IDs
$APP --cmd 41001 --insert "text" --quit-after 2     # type into the editor, then quit normally (saves session)
```

In `--snapshot` / `--quit-after` runs every alert is printed to stderr and answered with
its first button, so scripted runs never block. `-nosession` skips loading and saving
`session.xml`.

`--find-text`, `--find-replace`, `--find-dir`, `--find-filters` fill the Find dialog;
`--find-dlg <id>` presses a button (`1` Find Next, `1614` Count, `1641` Find All in
Current Document, `1636` Find All in Opened Documents, `1609` Replace All,
`1656` Find in Files, `1615` Mark All).

## Status

- [x] **Phase 1** — window, tabs, status bar, file I/O (ANSI/UTF-8/UTF-8-BOM/UTF-16), all languages and default styles, folding, bookmarks
- [x] **Phase 2** — menus generated from upstream, command-ID dispatch, Find / Replace / Find in Files / Mark (Normal, Extended, boost::regex), Search results panel, Incremental search, Find characters in range, Mark styles 1–5, bookmarked-line ops, change history, smart highlighting, generic `.rc` dialog loader
- [x] **Phase 3** — `config.xml` / `session.xml` in upstream format, session restore, snapshot backups, Load/Save Session, files changed/deleted outside the editor, all Encoding-menu codepages, uchardet detection (upstream's load order)
- [ ] **Phase 4** — toolbar, tab bar options and context menus, editor context menu
- [ ] **Phase 5** — themes, Style Configurator, dark mode
- [ ] **Phase 6** — Preferences dialog, localization (`nativeLang`)
- [ ] **Phase 7** — split view (move/clone), remaining Edit operations, Column editor, multi-select
- [ ] **Phase 8** — macros, Run menu, auto-completion and call tips, panels (Function list, Document list, Folder as Workspace, Document map, Project panels, Clipboard history, Character panel)
- [ ] **Phase 9** — User Defined Languages, printing, plugin support, Tools (MD5/SHA), final review

`--dump-menus` shows the exact remaining items.
