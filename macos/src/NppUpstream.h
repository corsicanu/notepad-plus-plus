// Upstream Notepad++ headers that are portable once compat/windows.h
// stands in for the Win32 types, plus the tables tools/gen_upstream.sh
// extracts from PowerEditor sources at build time.
#pragma once

#include <windows.h>
#include "Notepad_plus_msgs.h"
#include "NppConstants.h"
#include "menuCmdID.h"
#include "resource.h"
#include "Scintilla.h"
#include "SciLexer.h"

#include <cstddef>

// Markers reserved by Notepad++ (ScintillaEditView.h).
inline constexpr int MARK_BOOKMARK = 20;
inline constexpr int MARK_HIDELINESBEGIN = 19;
inline constexpr int MARK_HIDELINESEND = 18;

// Same layout as Parameters.cpp, so the extracted tables compile verbatim.
struct WinMenuKeyDefinition
{
	int vKey = 0;
	int functionId = 0;
	bool isCtrl = false;
	bool isAlt = false;
	bool isShift = false;
	const wchar_t* specialName = nullptr;
};

struct ScintillaKeyDefinition
{
	const wchar_t* name = nullptr;
	int functionId = 0;
	bool isCtrl = false;
	bool isAlt = false;
	bool isShift = false;
	int vKey = 0;
	int redirFunctionId = 0;
};

// Notepad_plus.cpp toolBarIcons[] row: command + icon resource names for
// light (regular, filled) and dark (regular, filled) sets, normal and disabled.
struct ToolbarIconDef
{
	int cmd;
	const char* icon;            // _defaultIcon (Fluent regular)
	const char* grayIcon;
	const char* icon2;           // Fluent filled
	const char* grayIcon2;
	const char* iconDM;
	const char* grayIconDM;
	const char* iconDM2;
	const char* grayIconDM2;
	const char* stdIcon;         // standard (bitmap) set
};

// MenuItemUnit as used for the default tab context menu.
struct MenuItemUnitDef
{
	int cmd = 0;
	const wchar_t* name = nullptr;
	const wchar_t* folder = nullptr;
};

// Host for functions lifted from Notepad_plus.cpp.
struct Notepad_plus
{
	static LangType menuID2LangType(int cmdID);
};

namespace NppUpstream
{
	const WinMenuKeyDefinition* winKeyDefs(size_t& count);
	const ScintillaKeyDefinition* scintKeyDefs(size_t& count);

	const ToolbarIconDef* toolbarIcons(size_t& count);
	const MenuItemUnitDef* defaultTabContextMenu(size_t& count);

	// Resolves an identifier used in Notepad_plus.rc (e.g. "IDM_FILE_NEW"); -1 if unknown.
	int menuIdByName(const char* name);
}
