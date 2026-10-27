#!/bin/sh
# Extracts pure tables/functions from upstream PowerEditor sources into
# include files, so the macOS app reuses them verbatim without the
# upstream files being edited.
#   gen_upstream.sh <PowerEditor/src> <outdir>
set -e
SRC="$1"
OUT="$2"
mkdir -p "$OUT"

RC="$SRC/Notepad_plus.rc"

# 1. Name -> value table for every command ID referenced by the main menu.
awk '/^IDR_M30_MENU MENU/{m=1} m&&/^IDR_SYSTRAYPOPUP_MENU/{m=0} m' "$RC" \
	| grep -E '^\s*MENUITEM' | grep -v SEPARATOR \
	| sed -E 's/.*"[[:space:]]*,[[:space:]]*([A-Za-z_0-9]+).*/\1/' \
	| sort -u | awk '{printf "\t{\"%s\", %s},\n", $1, $1}' > "$OUT/MenuIds.inc.tmp"
mv "$OUT/MenuIds.inc.tmp" "$OUT/MenuIds.inc"

# 2. Default keyboard shortcuts (Parameters.cpp: winKeyDefs[]).
awk '/static constexpr WinMenuKeyDefinition winKeyDefs\[\]/{m=1; next} m&&/^};/{exit} m&&!/^\{/' "$SRC/Parameters.cpp" > "$OUT/WinKeyDefs.inc.tmp"
mv "$OUT/WinKeyDefs.inc.tmp" "$OUT/WinKeyDefs.inc"

# 3. Scintilla command shortcuts (Parameters.cpp: scintKeyDefs[]).
awk '/static constexpr ScintillaKeyDefinition scintKeyDefs\[\]/{m=1; next} m&&/^};/{exit} m&&!/^\{/' "$SRC/Parameters.cpp" > "$OUT/ScintKeyDefs.inc.tmp"
mv "$OUT/ScintKeyDefs.inc.tmp" "$OUT/ScintKeyDefs.inc"

# 4. Menu command -> LangType (Notepad_plus.cpp).
awk '/^LangType Notepad_plus::menuID2LangType\(int cmdID\)/{m=1} m{print} m&&/^}/{exit}' "$SRC/Notepad_plus.cpp" > "$OUT/MenuID2LangType.inc.tmp"
mv "$OUT/MenuID2LangType.inc.tmp" "$OUT/MenuID2LangType.inc"

for f in MenuIds WinKeyDefs ScintKeyDefs MenuID2LangType; do
	[ -s "$OUT/$f.inc" ] || { echo "gen_upstream: $f.inc is empty, upstream layout changed" >&2; exit 1; }
done
