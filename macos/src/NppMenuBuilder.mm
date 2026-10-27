#import "NppMenuBuilder.h"

#include "NppUpstream.h"

#include <map>
#include <string>
#include <vector>

namespace
{
	// Standard responder-chain actions, so text fields in dialogs get
	// Cut/Copy/Paste/Undo too, not only the editor.
	SEL standardSelector(int cmd)
	{
		switch (cmd)
		{
			case IDM_EDIT_UNDO: return @selector(undo:);
			case IDM_EDIT_REDO: return @selector(redo:);
			case IDM_EDIT_CUT: return @selector(cut:);
			case IDM_EDIT_COPY: return @selector(copy:);
			case IDM_EDIT_PASTE: return @selector(paste:);
			case IDM_EDIT_SELECTALL: return @selector(selectAll:);
			case IDM_EDIT_DELETE: return @selector(delete:);
			default: return nullptr;
		}
	}

	// A few labels name Windows-only places; give the macOS equivalent.
	NSString* macLabel(int cmd, NSString* label)
	{
		return [NppMenuBuilder macTitle: label command: cmd];
	}

	struct Lexer
	{
		const std::vector<std::string>& lines;
		size_t i = 0;
	};

	std::string trim(const std::string& s)
	{
		size_t b = s.find_first_not_of(" \t\r");
		size_t e = s.find_last_not_of(" \t\r");
		return b == std::string::npos ? "" : s.substr(b, e - b + 1);
	}

	// Parses `"label", ID, FLAGS` / `"label"`; returns false if no quoted label.
	bool parseQuoted(const std::string& s, std::string& label, std::string& rest)
	{
		size_t q = s.find('"');
		if (q == std::string::npos)
			return false;
		label.clear();
		size_t i = q + 1;
		for (; i < s.size(); ++i)
		{
			if (s[i] == '"')
			{
				if (i + 1 < s.size() && s[i + 1] == '"') { label += '"'; ++i; continue; }
				break;
			}
			label += s[i];
		}
		rest = i + 1 < s.size() ? s.substr(i + 1) : "";
		return true;
	}

	NSMenu* parseBlock(Lexer& lx, NSString* title);

	void parseInto(Lexer& lx, NSMenu* menu, bool topLevel, std::vector<NSMenuItem*>* topItems)
	{
		while (lx.i < lx.lines.size())
		{
			std::string line = trim(lx.lines[lx.i++]);
			if (line.empty() || line.rfind("//", 0) == 0)
				continue;
			if (line == "END")
				return;
			if (line == "BEGIN")
				continue;

			if (line.rfind("POPUP", 0) == 0)
			{
				std::string label, rest;
				parseQuoted(line, label, rest);
				NSString* title = [NppMenuBuilder stripMnemonic: [NSString stringWithUTF8String: label.c_str()]];
				NSMenu* sub = parseBlock(lx, title);
				// "▼" is the tab-list drop-down Notepad++ draws in its menu bar.
				if (topLevel && label == "▼")
					continue;
				NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""];
				holder.submenu = sub;
				if (topItems)
					topItems->push_back(holder);
				else
					[menu addItem: holder];
				continue;
			}

			if (line.rfind("MENUITEM", 0) == 0)
			{
				if (line.find("SEPARATOR") != std::string::npos && line.find('"') == std::string::npos)
				{
					if (!topLevel)
						[menu addItem: NSMenuItem.separatorItem];
					continue;
				}
				std::string label, rest;
				if (!parseQuoted(line, label, rest))
					continue;
				// rest: ", ID[, FLAGS...]"
				std::string idName, flags;
				size_t c = rest.find(',');
				std::string after = c == std::string::npos ? rest : rest.substr(c + 1);
				size_t c2 = after.find(',');
				idName = trim(c2 == std::string::npos ? after : after.substr(0, c2));
				flags = c2 == std::string::npos ? "" : after.substr(c2 + 1);
				// Top-level HELP items ("＋", "✕") are Notepad++'s menu-bar tab buttons.
				if (topLevel)
					continue;

				int cmd = NppUpstream::menuIdByName(idName.c_str());
				NSString* title = [NppMenuBuilder stripMnemonic: [NSString stringWithUTF8String: label.c_str()]];
				title = macLabel(cmd, title);
				SEL std = standardSelector(cmd);
				NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: title action: std ?: @selector(nppCommand:) keyEquivalent: @""];
				mi.tag = cmd;
				if (flags.find("GRAYED") != std::string::npos)
					mi.enabled = NO;
				[menu addItem: mi];
			}
		}
	}

	NSMenu* parseBlock(Lexer& lx, NSString* title)
	{
		NSMenu* m = [[NSMenu alloc] initWithTitle: title];
		parseInto(lx, m, false, nullptr);
		return m;
	}

	NSString* keyString(int vKey, NSEventModifierFlags& mods)
	{
		auto fn = [](unichar c) { return [NSString stringWithCharacters: &c length: 1]; };
		if (vKey >= VK_A && vKey <= VK_Z)
			return [NSString stringWithFormat: @"%c", (char)('a' + vKey - VK_A)];
		if (vKey >= VK_0 && vKey <= VK_9)
			return [NSString stringWithFormat: @"%c", (char)('0' + vKey - VK_0)];
		if (vKey >= VK_NUMPAD0 && vKey <= VK_NUMPAD9)
		{
			mods |= NSEventModifierFlagNumericPad;
			return [NSString stringWithFormat: @"%c", (char)('0' + vKey - VK_NUMPAD0)];
		}
		if (vKey >= VK_F1 && vKey <= VK_F12)
			return fn(NSF1FunctionKey + (vKey - VK_F1));
		switch (vKey)
		{
			case VK_UP: return fn(NSUpArrowFunctionKey);
			case VK_DOWN: return fn(NSDownArrowFunctionKey);
			case VK_LEFT: return fn(NSLeftArrowFunctionKey);
			case VK_RIGHT: return fn(NSRightArrowFunctionKey);
			case VK_PRIOR: return fn(NSPageUpFunctionKey);
			case VK_NEXT: return fn(NSPageDownFunctionKey);
			case VK_HOME: return fn(NSHomeFunctionKey);
			case VK_END: return fn(NSEndFunctionKey);
			case VK_INSERT: return fn(NSInsertFunctionKey);
			case VK_DELETE: return fn(NSDeleteFunctionKey);
			case VK_BACK: return fn(0x08);
			case VK_RETURN: return @"\r";
			case VK_TAB: return @"\t";
			case VK_ESCAPE: return fn(0x1b);
			case VK_SPACE: return @" ";
			case VK_ADD: mods |= NSEventModifierFlagNumericPad; return @"+";
			case VK_SUBTRACT: mods |= NSEventModifierFlagNumericPad; return @"-";
			case VK_MULTIPLY: mods |= NSEventModifierFlagNumericPad; return @"*";
			case VK_DIVIDE: mods |= NSEventModifierFlagNumericPad; return @"/";
			case VK_DECIMAL: mods |= NSEventModifierFlagNumericPad; return @".";
			case VK_OEM_PLUS: return @"=";
			case VK_OEM_MINUS: return @"-";
			case VK_OEM_COMMA: return @",";
			case VK_OEM_PERIOD: return @".";
			case VK_OEM_1: return @";";
			case VK_OEM_2: return @"/";
			case VK_OEM_3: return @"`";
			case VK_OEM_4: return @"[";
			case VK_OEM_5: return @"\\";
			case VK_OEM_6: return @"]";
			case VK_OEM_7: return @"'";
			default: return nil;
		}
	}

	void collect(NSMenu* menu, std::map<int, NSMenuItem*>& byTag)
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			if (mi.submenu)
				collect(mi.submenu, byTag);
			else if (mi.tag > 0 && !byTag.count((int)mi.tag))
				byTag[(int)mi.tag] = mi;
		}
	}

	void assign(NSMenuItem* mi, int vKey, bool ctrl, bool alt, bool shift)
	{
		if (!mi || vKey == 0 || mi.keyEquivalent.length)
			return;
		NSEventModifierFlags mods = 0;
		NSString* key = keyString(vKey, mods);
		if (!key)
			return;
		// Ctrl -> Cmd, Alt -> Option. Ctrl+Tab stays on Control: Cmd+Tab belongs to macOS.
		if (ctrl)
			mods |= vKey == VK_TAB ? NSEventModifierFlagControl : NSEventModifierFlagCommand;
		if (alt)
			mods |= NSEventModifierFlagOption;
		if (shift)
			mods |= NSEventModifierFlagShift;
		// Cmd+Q is Quit on macOS; Notepad++'s Ctrl+Q (toggle comment) moves to Cmd+/.
		if ((mods & NSEventModifierFlagCommand) && !(mods & (NSEventModifierFlagShift | NSEventModifierFlagOption)) && [key isEqualToString: @"q"])
			key = @"/";
		mi.keyEquivalent = key;
		mi.keyEquivalentModifierMask = mods;
	}
}

@implementation NppMenuBuilder

+ (NSString*)macTitle:(NSString*)title command:(int)cmd
{
	auto swap = [&](NSString* from, NSString* to) {
		title = [title stringByReplacingOccurrencesOfString: from withString: to];
	};
	switch (cmd)
	{
		case IDM_FILE_OPEN_FOLDER:
			if ([title isEqualToString: @"Explorer"])
				return @"Finder";
			swap(@"Explorer", @"Finder");
			break;
		case IDM_FILE_OPEN_CMD:
			if ([title isEqualToString: @"cmd"])
				return @"Terminal";
			swap(@" cmd", @" Terminal");
			break;
		case IDM_FILE_DELETE:
			swap(@"Recycle Bin", @"Trash");
			break;
		case IDM_EDIT_TOGGLESYSTEMREADONLY:
			swap(@"Windows", @"macOS");
			break;
		case IDM_EDIT_OPENSELECTEDFILEFOLDERINEXPLORER:
			swap(@"Explorer", @"Finder");
			break;
	}
	return title;
}

+ (NSString*)stripMnemonic:(NSString*)label
{
	NSMutableString* out = [NSMutableString string];
	for (NSUInteger i = 0; i < label.length; ++i)
	{
		unichar c = [label characterAtIndex: i];
		if (c == '&')
		{
			if (i + 1 < label.length && [label characterAtIndex: i + 1] == '&')
			{
				[out appendString: @"&"];
				++i;
			}
			continue;
		}
		if (c == '\t')
			break;
		[out appendFormat: @"%C", c];
	}
	return out;
}

+ (NSArray<NSMenuItem*>*)mainMenuItemsFromRC:(NSString*)rcPath
{
	NSString* rc = [NSString stringWithContentsOfFile: rcPath encoding: NSUTF8StringEncoding error: nil];
	if (!rc)
		return @[];

	std::vector<std::string> lines;
	bool inMenu = false;
	for (NSString* l in [rc componentsSeparatedByString: @"\n"])
	{
		if ([l hasPrefix: @"IDR_M30_MENU MENU"])
		{
			inMenu = true;
			continue;
		}
		if (inMenu)
		{
			if ([l hasPrefix: @"IDR_"])
				break;
			lines.push_back(l.UTF8String);
		}
	}

	Lexer lx{lines};
	std::vector<NSMenuItem*> top;
	// Skip the outer BEGIN, then parse top-level popups until the outer END.
	parseInto(lx, nil, true, &top);
	NSMutableArray* out = [NSMutableArray array];
	for (NSMenuItem* mi : top)
		[out addObject: mi];
	return out;
}

+ (void)applyDefaultShortcuts:(NSMenu*)menu
{
	std::map<int, NSMenuItem*> byTag;
	collect(menu, byTag);

	// A macOS menu item holds one shortcut. When Notepad++ binds several to one
	// command, prefer the Ctrl+letter form over legacy Shift+Del / Ctrl+Ins ones.
	auto isLegacy = [](const WinMenuKeyDefinition& d) {
		return d.vKey == VK_INSERT || (d.vKey == VK_DELETE && d.isShift) || (d.vKey == VK_BACK && d.isAlt);
	};
	size_t n = 0;
	const WinMenuKeyDefinition* defs = NppUpstream::winKeyDefs(n);
	std::map<int, const WinMenuKeyDefinition*> best;
	for (size_t i = 0; i < n; ++i)
	{
		if (!defs[i].vKey)
			continue;
		auto cur = best.find(defs[i].functionId);
		if (cur == best.end() || (isLegacy(*cur->second) && !isLegacy(defs[i])))
			best[defs[i].functionId] = &defs[i];
	}
	// Exit is Cmd+Q in the application menu; Alt+F4 means nothing on macOS.
	best.erase(IDM_FILE_EXIT);
	for (const auto& [cmd, d] : best)
	{
		auto it = byTag.find(cmd);
		if (it != byTag.end())
			assign(it->second, d->vKey, d->isCtrl, d->isAlt, d->isShift);
	}

	// Scintilla commands redirected to menu items (Select All, Undo, ...).
	const ScintillaKeyDefinition* sdefs = NppUpstream::scintKeyDefs(n);
	for (size_t i = 0; i < n; ++i)
	{
		if (!sdefs[i].redirFunctionId)
			continue;
		auto it = byTag.find(sdefs[i].redirFunctionId);
		if (it != byTag.end())
			assign(it->second, sdefs[i].vKey, sdefs[i].isCtrl, sdefs[i].isAlt, sdefs[i].isShift);
	}
}

@end
