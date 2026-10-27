# Notepad++ for macOS

Native Cocoa port of Notepad++, built on Scintilla's Cocoa backend and Lexilla.

## Layout

- `macos/` holds everything macOS-specific. The upstream folders
  (`PowerEditor/`, `scintilla/`, `lexilla/`, `boostregex/`) are not modified,
  so `master` can keep tracking upstream and be merged into `macos` cleanly.
- Upstream data files are copied into the app bundle at build time:
  `langs.model.xml`, `stylers.model.xml`, `installer/themes/*.xml`,
  `installer/nativeLang/*.xml`.
- `macos/compat/windows.h` is a tiny shim so Notepad++'s own lexers
  (`LexUser.cxx`) compile unchanged.

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

Headless UI check (no screen-recording permission needed):

```bash
~/Library/Caches/NotepadPP-build/Notepad++.app/Contents/MacOS/Notepad++ --snapshot /tmp/npp.png somefile.cpp
```

## Status

Phase 1 (done):
- Main window: tab bar, single Scintilla view swapping documents per tab, status bar
- All Notepad++ languages, keywords and default styles from the upstream XML
- Line numbers, bookmark margin, box-tree folding, brace highlight
- File: New, Open, Recent Files, Reload, Save, Save As, Save All, Close, Close All
- Encodings: ANSI (Windows-1252), UTF-8, UTF-8-BOM, UTF-16 BE/LE BOM; EOL conversion
- Edit: line operations, case conversion, toggle single-line comment
- Search: Go to line, bookmarks
- View: show symbols, indent guides, word wrap, zoom, fold/unfold all

Next phases: Find/Replace dialog (with boostregex), session restore, themes
and Style Configurator, preferences, toolbar, localization, split view,
Find in Files, macros, auto-completion and function list.
