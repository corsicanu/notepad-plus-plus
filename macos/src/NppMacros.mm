// Macro and Run menus: port of Notepad++'s macro recording / playback
// (NppCommands.cpp, NppNotification.cpp SCN_MACRORECORD, NppBigSwitch.cpp
// WM_MACRODLGRUNMACRO), RunDlg, RunMacroDlg and the Shortcut dialog used to
// save macros and commands into shortcuts.xml.

#import "NppMainWindowInternal.h"
#import "NppMenuBuilder.h"
#import "NppRcDialog.h"
#import "NppLocalization.h"
#import "NppShortcutMapper.h"

#include "NppShortcuts.h"
#include "NppConfig.h"
#include "NppUpstream.h"
#include "shortcutRc.h"
#include "RunDlg_rc.h"
#include "RunMacroDlg_rc.h"

#include <algorithm>
#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

@interface NppMainWindow (MacrosHost)
- (BOOL)runCommand:(int)cmd;
- (NSArray<ScintillaView*>*)allEditors;
- (void)notification:(SCNotification*)n;
@end

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	// Notepad_plus::_recordingMacro, _macro, _recordingSaved, _playingBackMacro.
	bool recordingMacro = false;
	bool recordingSaved = false;
	bool playingBackMacro = false;
	NppMacro currentMacro;

	// Menu items switched to the command table while recording, so their
	// Scintilla messages go through WndProc and get recorded.
	const int responderEditCommands[] = { IDM_EDIT_CUT, IDM_EDIT_COPY, IDM_EDIT_PASTE, IDM_EDIT_DELETE, IDM_EDIT_SELECTALL };

	void forEachItem(NSMenu* menu, void (^block)(NSMenuItem*))
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			block(mi);
			if (mi.submenu)
				forEachItem(mi.submenu, block);
		}
	}

	NSMenu* menuContaining(NSMenu* bar, int cmd)
	{
		__block NSMenu* found = nil;
		forEachItem(bar, ^(NSMenuItem* mi) {
			if (!found && mi.tag == cmd && mi.action == @selector(nppCommand:))
				found = mi.menu;
		});
		return found;
	}

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

}

// Port of the Shortcut dialog (IDD_SHORTCUT_DLG): name + key. The name is
// read-only for menu commands (_canModifyName).
bool nppShortcutDialog(NppShortcutEntry& e, NSString* title, BOOL nameEditable)
{
	NppRcDialog* dlg = [[NppRcDialog alloc] initWithRC: @"shortcut.rc" dialog: @"IDD_SHORTCUT_DLG"];
	[NppLocalization applyToDialog: dlg node: @"ShortcutMapper"];
	if (title)
		dlg.window.title = title;
	NSMutableArray* names = [NSMutableArray array];
	NSInteger sel = 0;
	const auto& keys = NppShortcuts::namedKeys();
	for (size_t i = 0; i < keys.size(); ++i)
	{
		[names addObject: ns(keys[i].first)];
		if (keys[i].second == e._keyCombo._key)
			sel = i;
	}
	[dlg setItems: names forList: IDC_KEY_COMBO];
	[dlg select: sel inList: IDC_KEY_COMBO];
	[dlg setText: IDC_NAME_EDIT value: ns(e._name)];
	[dlg enable: IDC_NAME_EDIT value: nameEditable];
	[dlg setChecked: IDC_CTRL_CHECK value: e._keyCombo._isCtrl];
	[dlg setChecked: IDC_ALT_CHECK value: e._keyCombo._isAlt];
	[dlg setChecked: IDC_SHIFT_CHECK value: e._keyCombo._isShift];
	[dlg show: IDC_WARNING_STATIC value: NO];
	[dlg show: IDC_CONFLICT_STATIC value: NO];
	auto updateOK = [dlg] { [dlg enable: IDOK value: [dlg text: IDC_NAME_EDIT].length > 0]; };
	updateOK();
	dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
		if (cid == IDC_NAME_EDIT)
		{
			[d enable: IDOK value: [d text: IDC_NAME_EDIT].length > 0];
			return YES;
		}
		if (cid == IDOK && [d text: IDC_NAME_EDIT].length == 0)
			return YES;
		return NO;
	};
	if ([dlg runModal] != IDOK)
		return false;
	e._name = [dlg text: IDC_NAME_EDIT].UTF8String ?: "";
	e._keyCombo._isCtrl = [dlg isChecked: IDC_CTRL_CHECK];
	e._keyCombo._isAlt = [dlg isChecked: IDC_ALT_CHECK];
	e._keyCombo._isShift = [dlg isChecked: IDC_SHIFT_CHECK];
	NSInteger k = [dlg selectedIndex: IDC_KEY_COMBO];
	e._keyCombo._key = (k >= 0 && k < (NSInteger)keys.size()) ? keys[k].second : 0;
	return true;
}

@implementation NppMainWindow (Macros)

#pragma mark - Commands

+ (void)registerMacroCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	for (int id : {IDM_MACRO_STARTRECORDINGMACRO, IDM_MACRO_STOPRECORDINGMACRO, IDC_EDIT_TOGGLEMACRORECORDING})
		t[id] = ^(NppMainWindow* w) { [w toggleMacroRecording]; };
	t[IDM_MACRO_PLAYBACKRECORDEDMACRO] = ^(NppMainWindow* w) {
		if (!recordingMacro)
			[w macroPlayback: currentMacro docs: nullptr];
	};
	t[IDM_MACRO_SAVECURRENTMACRO] = ^(NppMainWindow* w) {
		NppMacroShortcut ms;
		if (nppShortcutDialog(ms, nil, YES))
			[w addCurrentMacro: ms];
	};
	t[IDM_MACRO_RUNMULTIMACRODLG] = ^(NppMainWindow* w) {
		if (!recordingMacro)
			[w showRunMacroDialog];
	};
	t[IDM_EXECUTE] = ^(NppMainWindow* w) { [w showRunDialog]; };
	t[IDM_EXECUTE_VALIDATE_SHORTCUTSXML] = ^(NppMainWindow*) { NppShortcuts::instance().validate(); };
	t[IDM_SETTING_SHORTCUT_MAPPER] = ^(NppMainWindow* w) { [NppShortcutMapper showForWindow: w tab: NppShortcutMapperMainMenu]; };
	t[IDM_SETTING_SHORTCUT_MAPPER_MACRO] = ^(NppMainWindow* w) { [NppShortcutMapper showForWindow: w tab: NppShortcutMapperMacros]; };
	t[IDM_SETTING_SHORTCUT_MAPPER_RUN] = ^(NppMainWindow* w) { [NppShortcutMapper showForWindow: w tab: NppShortcutMapperRunCommands]; };
}

// Upstream checkMacroState.
- (BOOL)validateMacroCommand:(int)cmd
{
	const auto& macros = NppShortcuts::instance()._macros;
	switch (cmd)
	{
		case IDM_MACRO_STARTRECORDINGMACRO: return !recordingMacro;
		case IDM_MACRO_STOPRECORDINGMACRO: return recordingMacro;
		case IDM_MACRO_PLAYBACKRECORDEDMACRO: return !recordingMacro && !currentMacro.empty();
		case IDM_MACRO_SAVECURRENTMACRO: return !recordingMacro && !currentMacro.empty() && !recordingSaved;
		case IDM_MACRO_RUNMULTIMACRODLG: return !recordingMacro && (!currentMacro.empty() || !macros.empty());
	}
	return YES;
}

+ (BOOL)isShortcutsXmlCommand:(int)cmd
{
	return (cmd >= ID_MACRO && cmd < ID_MACRO_LIMIT) || (cmd >= ID_USER_CMD && cmd < ID_USER_CMD_LIMIT);
}

// Macros and Run menu commands from shortcuts.xml, after the integrity check.
- (void)runShortcutsXmlCommand:(int)cmd
{
	NppShortcuts& sc = NppShortcuts::instance();
	if (!sc.isTrusted())
	{
		BOOL missing = sc.hmacMissing();
		[self openPaths: @[ns(sc.path())]];
		if (NppBuffer* b = [self currentBuffer])
		{
			b.readOnly = YES;
			[self refreshTabs];
		}
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"Security Warning";
		a.informativeText = missing
			? @"The security information for shortcuts.xml is missing in config.xml.\n\nFor security reasons, the integrity of shortcuts.xml will be checked. To run your customized command, please review the opened shortcuts.xml. If the file content is OK, use \"Validate shortcuts.xml\" from the \"Run\" menu to confirm it."
			: @"The shortcuts.xml file appears to have been modified manually.\n\nFor security reasons, please review the opened shortcuts.xml. If the file content is OK, use \"Validate shortcuts.xml\" from the \"Run\" menu to confirm it.";
		[a runModal];
		return;
	}
	if (cmd >= ID_MACRO && cmd < ID_MACRO_LIMIT)
	{
		size_t i = cmd - ID_MACRO;
		if (i < sc._macros.size())
			[self macroPlayback: sc._macros[i]._macro docs: nullptr];
	}
	else
	{
		size_t i = cmd - ID_USER_CMD;
		if (i < sc._userCommands.size())
			[self runUserCommand: sc._userCommands[i]._cmd];
	}
}

#pragma mark - Recording

- (BOOL)isRecordingMacro
{
	return recordingMacro;
}

- (BOOL)isPlayingBackMacro
{
	return playingBackMacro;
}

- (void)toggleMacroRecording
{
	NSArray<ScintillaView*>* editors = [self allEditors];
	if (recordingMacro)
	{
		for (ScintillaView* e in editors)
		{
			sci(e, SCI_STOPRECORD);
			sci(e, SCI_SETCURSOR, SC_CURSORNORMAL);
		}
		recordingMacro = false;
		self.findReplaceDlg.macroRecorder = nil;
	}
	else
	{
		currentMacro.clear();
		for (ScintillaView* e in editors)
		{
			sci(e, SCI_SETCURSOR, 9);
			sci(e, SCI_STARTRECORD);
		}
		recordingMacro = true;
		// WM_FRSAVE_INT / WM_FRSAVE_STR
		self.findReplaceDlg.macroRecorder = ^(int what, long intValue, NSString* str) {
			if (str)
				currentMacro.emplace_back(what, 0, 0, str.UTF8String, NppMacroStep::mtSavedSnR);
			else
				currentMacro.emplace_back(what, 0, intValue, nullptr, NppMacroStep::mtSavedSnR);
		};
	}
	recordingSaved = false;
	[self routeEditMenuForRecording: recordingMacro];
}

- (void)routeEditMenuForRecording:(BOOL)recording
{
	static const std::unordered_map<int, SEL> selectors = {
		{IDM_EDIT_CUT, @selector(cut:)}, {IDM_EDIT_COPY, @selector(copy:)}, {IDM_EDIT_PASTE, @selector(paste:)},
		{IDM_EDIT_DELETE, @selector(delete:)}, {IDM_EDIT_SELECTALL, @selector(selectAll:)},
	};
	forEachItem(NSApp.mainMenu, ^(NSMenuItem* mi) {
		for (int cmd : responderEditCommands)
			if (mi.tag == cmd && !mi.submenu)
				mi.action = recording ? @selector(nppCommand:) : selectors.at(cmd);
	});
}

// SCN_MACRORECORD (NppNotification.cpp), with its EOL normalization.
- (void)macroRecordNotification:(SCNotification*)n
{
	if (!recordingMacro)
		return;
	if (n->message == SCI_REPLACESEL)
	{
		const char* ch = reinterpret_cast<const char*>(n->lParam);
		if (ch && ch[0] != '\0' && ch[1] == '\0' && (ch[0] == '\n' || ch[0] == '\r'))
		{
			if ([self currentBuffer].eol == NppEOLWindows && ch[0] == '\n' && !currentMacro.empty() && currentMacro.back()._message == SCI_NEWLINE)
				currentMacro.pop_back();
			currentMacro.emplace_back(SCI_NEWLINE, 0, 0, nullptr, 0);
			return;
		}
	}
	currentMacro.emplace_back(static_cast<int>(n->message), n->wParam, n->lParam);
}

// Runs a menu command, recording it when it is one Notepad++ records. The
// Scintilla messages the command sent itself are dropped, so playback
// doesn't apply them twice.
- (void)recordCommand:(int)cmd run:(void (^)(void))run
{
	if (!recordingMacro)
	{
		run();
		return;
	}
	size_t before = currentMacro.size();
	run();
	if (!recordingMacro)
		return; // the command stopped the recording
	if (NppShortcuts::isMacroableCommand(cmd))
	{
		currentMacro.resize(std::min(before, currentMacro.size()), NppMacroStep(0));
		currentMacro.emplace_back(cmd);
	}
}

#pragma mark - Playback

// Port of Notepad_plus::macroPlayback: one undo action per touched document.
- (void)macroPlayback:(const NppMacro&)macro docs:(std::vector<sptr_t>*)docsIn
{
	playingBackMacro = true;
	std::vector<sptr_t> local;
	std::vector<sptr_t>* docs = docsIn ? docsIn : &local;

	sptr_t prevDoc = 0;
	for (const NppMacroStep& step : macro)
	{
		sptr_t curDoc = sci(self.editor, SCI_GETDOCPOINTER);
		if (curDoc != prevDoc)
		{
			if (std::find(docs->begin(), docs->end(), curDoc) == docs->end())
			{
				sci(self.editor, SCI_BEGINUNDOACTION);
				docs->push_back(curDoc);
			}
			prevDoc = curDoc;
		}

		if (step._macroType == NppMacroStep::mtMenuCommand)
			[self runCommand: static_cast<int>(step._wParameter)];
		else if (step._macroType == NppMacroStep::mtSavedSnR)
			[self.findReplaceDlg execSavedCommand: step._message intValue: static_cast<long>(step._lParameter) string: ns(step._sParameter)];
		else if (step.isMacroable())
		{
			// recordedMacroStep::PlayBack
			ScintillaView* e = self.editor;
			if (step._macroType == NppMacroStep::mtUseSParameter)
				sci(e, step._message, step._wParameter, reinterpret_cast<sptr_t>(step._sParameter.c_str()));
			else
				sci(e, step._message, step._wParameter, step._lParameter);
			switch (step._message)
			{
				case SCI_SETTEXT: case SCI_REPLACESEL: case SCI_ADDTEXT:
				case SCI_ADDSTYLEDTEXT: case SCI_INSERTTEXT: case SCI_APPENDTEXT:
				{
					SCNotification scn{};
					scn.nmhdr.code = SCN_CHARADDED;
					scn.ch = step._sParameter.empty() ? 0 : step._sParameter[0];
					[self notification: &scn];
					break;
				}
			}
		}
	}

	if (!docsIn)
		[self endMacroUndoActions: local];
	playingBackMacro = false;
}

- (void)endMacroUndoActions:(std::vector<sptr_t>&)docs
{
	ScintillaView* e = self.editor;
	sptr_t cur = sci(e, SCI_GETDOCPOINTER);
	ScintillaView* other = nil;
	while (!docs.empty())
	{
		sptr_t doc = docs.back();
		docs.pop_back();
		if (doc == cur)
			sci(e, SCI_ENDUNDOACTION);
		else
		{
			if (!other)
				other = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 10, 10)];
			sci(other, SCI_SETDOCPOINTER, 0, doc);
			sci(other, SCI_ENDUNDOACTION);
			sci(other, SCI_SETDOCPOINTER, 0, 0);
		}
	}
}

// Port of the WM_MACRODLGRUNMACRO loop: N times, or until the end of file.
- (void)runMacro:(const NppMacro&)m times:(int)times
{
	int counter = 0;
	ScintillaView* e = self.editor;
	auto currentLine = [e] { return sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS)); };
	intptr_t lastLine = sci(e, SCI_GETLINECOUNT) - 1;
	intptr_t currLine = currentLine();
	intptr_t deltaLastLine = 0;
	intptr_t deltaCurrLine = 0;
	bool cursorMovedUp = false;

	std::vector<sptr_t> docs;
	for (;;)
	{
		[self macroPlayback: m docs: &docs];
		e = self.editor;
		++counter;
		if (times >= 0)
		{
			if (counter >= times)
				break;
		}
		else
		{
			if (counter > 2 && cursorMovedUp != (deltaCurrLine < 0) && deltaLastLine >= 0)
				break;
			cursorMovedUp = deltaCurrLine < 0;
			deltaLastLine = sci(e, SCI_GETLINECOUNT) - 1 - lastLine;
			deltaCurrLine = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS)) - currLine;

			if (deltaCurrLine == 0 && deltaLastLine >= 0)
				break;
			if (deltaLastLine < deltaCurrLine)
				lastLine += deltaLastLine;
			currLine += deltaCurrLine;
			if (currLine > lastLine || currLine < 0 || (deltaCurrLine == 0 && currLine == 0 && (deltaLastLine >= 0 || cursorMovedUp)))
				break;
		}
	}
	[self endMacroUndoActions: docs];
}

#pragma mark - Saving

// Port of Notepad_plus::addCurrentMacro.
- (void)addCurrentMacro:(NppMacroShortcut)ms
{
	ms._macro = currentMacro;
	NppShortcuts& sc = NppShortcuts::instance();
	if (sc._macros.size() >= static_cast<size_t>(ID_MACRO_LIMIT - ID_MACRO))
		return;
	sc._macros.push_back(ms);
	sc.save();
	recordingSaved = true;
	[NppMainWindow installShortcutsXmlItemsIn: NSApp.mainMenu];
}

- (void)saveCurrentMacroNamed:(NSString*)name
{
	NppMacroShortcut ms;
	ms._name = name.UTF8String ?: "";
	[self addCurrentMacro: ms];
}

#pragma mark - Menus

// The Macro and Run menus' shortcuts.xml part (DynamicMenu): items, folders
// (FolderName), then the Shortcut Mapper entry.
+ (void)installShortcutsXmlItemsIn:(NSMenu*)bar
{
	const NppShortcuts& sc = NppShortcuts::instance();

	auto fill = [bar](int anchorCmd, int mapperCmd, NSString* mapperLabel, const std::vector<std::pair<const NppShortcutEntry*, int>>& entries, bool beforeAnchorSeparator) {
		NSMenu* menu = menuContaining(bar, anchorCmd);
		if (!menu)
			return;
		for (NSMenuItem* mi in [menu.itemArray copy])
			if ([mi.representedObject isEqual: @"shortcuts.xml"])
				[menu removeItem: mi];
		if (entries.empty())
			return;

		// Macro menu: after the last item; Run menu: right after "Run...".
		NSInteger pos = beforeAnchorSeparator ? [menu indexOfItemWithTag: anchorCmd] + 1 : menu.numberOfItems;
		auto insert = [&](NSMenuItem* mi) {
			mi.representedObject = @"shortcuts.xml";
			[menu insertItem: mi atIndex: pos++];
		};
		auto separator = [&] { insert([NSMenuItem separatorItem]); };

		separator();
		NSMutableDictionary<NSString*, NSMenu*>* folders = [NSMutableDictionary dictionary];
		for (const auto& [e, cmd] : entries)
		{
			NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: ns(e->_name) action: @selector(nppCommand:) keyEquivalent: @""];
			mi.tag = cmd;
			[NppMenuBuilder setShortcutOf: mi key: e->_keyCombo._key ctrl: e->_keyCombo._isCtrl alt: e->_keyCombo._isAlt shift: e->_keyCombo._isShift];
			if (e->_folderName.empty())
			{
				insert(mi);
				continue;
			}
			NSString* folder = ns(e->_folderName);
			NSMenu* sub = folders[folder];
			if (!sub)
			{
				sub = [[NSMenu alloc] initWithTitle: folder];
				folders[folder] = sub;
				NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle: folder action: nil keyEquivalent: @""];
				holder.submenu = sub;
				insert(holder);
			}
			[sub addItem: mi];
		}
		separator();
		NSMenuItem* mapper = [[NSMenuItem alloc] initWithTitle: mapperLabel action: @selector(nppCommand:) keyEquivalent: @""];
		mapper.tag = mapperCmd;
		insert(mapper);
	};

	std::vector<std::pair<const NppShortcutEntry*, int>> macros, commands;
	for (size_t i = 0; i < sc._macros.size(); ++i)
		macros.push_back({&sc._macros[i], ID_MACRO + static_cast<int>(i)});
	for (size_t i = 0; i < sc._userCommands.size(); ++i)
		commands.push_back({&sc._userCommands[i], ID_USER_CMD + static_cast<int>(i)});
	fill(IDM_MACRO_RUNMULTIMACRODLG, IDM_SETTING_SHORTCUT_MAPPER_MACRO, @"Modify Shortcut/Delete Macro...", macros, false);
	fill(IDM_EXECUTE, IDM_SETTING_SHORTCUT_MAPPER_RUN, @"Modify Shortcut/Delete Command...", commands, true);
}

#pragma mark - Run dialog

- (std::string)runVariable:(const std::string&)name
{
	NppBuffer* b = [self currentBuffer];
	NSString* full = b.path ?: b.displayName ?: @"";
	ScintillaView* e = self.editor;
	NSString* v = @"";
	if (name == "FULL_CURRENT_PATH")
		v = full;
	else if (name == "CURRENT_DIRECTORY")
		v = b.path ? full.stringByDeletingLastPathComponent : @"";
	else if (name == "FILE_NAME")
		v = full.lastPathComponent;
	else if (name == "NAME_PART")
		v = full.lastPathComponent.stringByDeletingPathExtension;
	else if (name == "EXT_PART")
		v = full.pathExtension.length ? [@"." stringByAppendingString: full.pathExtension] : @"";
	else if (name == "CURRENT_WORD")
		v = [self selectedTextOrWord: YES] ?: @"";
	else if (name == "NPP_DIRECTORY")
		v = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
	else if (name == "NPP_FULL_FILE_PATH")
		v = NSBundle.mainBundle.executablePath;
	else if (name == "CURRENT_LINE")
		v = [NSString stringWithFormat: @"%ld", sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS))];
	else if (name == "CURRENT_COLUMN")
		v = [NSString stringWithFormat: @"%ld", sci(e, SCI_GETCOLUMN, sci(e, SCI_GETCURRENTPOS))];
	else if (name == "CURRENT_LINESTR")
	{
		long line = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS));
		long s = sci(e, SCI_POSITIONFROMLINE, line), en = sci(e, SCI_GETLINEENDPOSITION, line);
		std::string text(en - s + 1, '\0');
		Sci_TextRangeFull tr{{s, en}, text.data()};
		sci(e, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
		text.resize(en - s);
		return text;
	}
	return v.UTF8String ?: "";
}

- (void)runUserCommand:(const std::string&)cmd
{
	__weak NppMainWindow* weakSelf = self;
	std::string err = nppRunCommand(cmd, [weakSelf](const std::string& name) { return [weakSelf runVariable: name]; });
	if (!err.empty())
	{
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"ShellExecute - ERROR";
		a.informativeText = ns(err);
		[a runModal];
	}
}

- (void)showRunDialog
{
	static NppRcDialog* dlg;
	static NSMutableArray<NSString*>* history = [NSMutableArray array];
	if (!dlg)
	{
		dlg = [[NppRcDialog alloc] initWithRC: @"RunDlg.rc" dialog: @"IDD_RUN_DLG"];
		[NppLocalization applyToDialog: dlg node: @"Run"];
	}
	__weak NppMainWindow* weakSelf = self;
	dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
		NSString* cmd = [d text: IDC_COMBO_RUN_PATH];
		switch (cid)
		{
			case IDOK:
			{
				if (!cmd.length)
					return YES;
				[history removeObject: cmd];
				[history insertObject: cmd atIndex: 0];
				[d setItems: history forList: IDC_COMBO_RUN_PATH];
				[d setText: IDC_COMBO_RUN_PATH value: cmd];
				[d endWith: IDOK];
				[weakSelf runUserCommand: cmd.UTF8String];
				return YES;
			}
			case IDC_BUTTON_FILE_BROWSER:
			{
				NSOpenPanel* p = [NSOpenPanel openPanel];
				p.treatsFilePackagesAsDirectories = NO;
				if ([p runModal] == NSModalResponseOK)
				{
					NSString* path = p.URL.path;
					if ([path rangeOfString: @" "].location != NSNotFound)
						path = [NSString stringWithFormat: @"\"%@\"", path];
					[d setText: IDC_COMBO_RUN_PATH value: path];
				}
				return YES;
			}
			case IDC_BUTTON_VARIABLES:
			{
				// IDR_RUN_DLG_MENU_VARIABLES
				static const char* const vars[][2] = {
					{"FULL_CURRENT_PATH", "Full path to active file"}, {"CURRENT_DIRECTORY", "Active file's directory"},
					{"FILE_NAME", "Active file's name"}, {"NAME_PART", "File name without extension"},
					{"EXT_PART", "File extension (with .)"}, {"CURRENT_WORD", "Selected word or word under caret"},
					{"NPP_DIRECTORY", "Notepad++ executable directory"}, {"NPP_FULL_FILE_PATH", "Full path of Notepad++ executable"},
					{"CURRENT_LINE", "Line number of caret"}, {"CURRENT_COLUMN", "Column number of caret"},
					{"CURRENT_LINESTR", "Current line text"},
				};
				NSMenu* m = [[NSMenu alloc] init];
				for (const auto& v : vars)
				{
					NSMenuItem* mi = [m addItemWithTitle: [NSString stringWithFormat: @"%s\t%s", v[0], v[1]] action: nil keyEquivalent: @""];
					mi.representedObject = @(v[0]);
				}
				NSView* button = [d item: IDC_BUTTON_VARIABLES];
				NSMenuItem* chosen = nil;
				if ([m popUpMenuPositioningItem: nil atLocation: NSMakePoint(0, button.bounds.size.height) inView: button])
					chosen = m.highlightedItem;
				if (chosen)
					[d setText: IDC_COMBO_RUN_PATH value: [cmd stringByAppendingFormat: @"$(%@)", chosen.representedObject]];
				return YES;
			}
			case IDC_BUTTON_SAVE:
			{
				if (!cmd.length)
					return YES;
				NppUserCommand uc;
				if (!nppShortcutDialog(uc, nil, YES))
					return YES;
				uc._cmd = cmd.UTF8String;
				NppShortcuts& sc = NppShortcuts::instance();
				if (sc._userCommands.size() < static_cast<size_t>(ID_USER_CMD_LIMIT - ID_USER_CMD))
				{
					sc._userCommands.push_back(uc);
					sc.save();
					[NppMainWindow installShortcutsXmlItemsIn: NSApp.mainMenu];
				}
				return YES;
			}
		}
		return NO;
	};
	[dlg setItems: history forList: IDC_COMBO_RUN_PATH];
	if (history.count)
		[dlg setText: IDC_COMBO_RUN_PATH value: history[0]];
	[dlg showModeless];
}

#pragma mark - Run a Macro Multiple Times

- (void)showRunMacroDialog
{
	static NppRcDialog* dlg;
	if (!dlg)
	{
		dlg = [[NppRcDialog alloc] initWithRC: @"RunMacroDlg.rc" dialog: @"IDD_RUN_MACRO_DLG"];
		[NppLocalization applyToDialog: dlg node: @"MultiMacro"];
		[dlg setChecked: IDC_M_RUN_MULTI value: YES];
		[dlg setText: IDC_M_RUN_TIMES value: @"1"];
	}
	// RunMacroDlg::initMacroList: the recorded macro first, then the saved ones.
	NSMutableArray* names = [NSMutableArray array];
	if (!currentMacro.empty())
		[names addObject: @"Current recorded macro"];
	for (const auto& m : NppShortcuts::instance()._macros)
		[names addObject: ns(m._name)];
	[dlg setItems: names forList: IDC_MACRO_COMBO];
	[dlg select: 0 inList: IDC_MACRO_COMBO];

	__weak NppMainWindow* weakSelf = self;
	dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
		switch (cid)
		{
			case IDC_M_RUN_MULTI:
			case IDC_M_RUN_EOF:
				[d enable: IDC_M_RUN_TIMES value: [d isChecked: IDC_M_RUN_MULTI]];
				return YES;
			case IDOK:
			{
				NSInteger idx = [d selectedIndex: IDC_MACRO_COMBO];
				if (idx < 0)
					return YES;
				// getMacro2Exec: -1 is the recorded macro.
				int macroIndex = currentMacro.empty() ? static_cast<int>(idx) : static_cast<int>(idx) - 1;
				if (macroIndex >= 0 && !NppShortcuts::instance().isTrusted())
				{
					[weakSelf runShortcutsXmlCommand: ID_MACRO + macroIndex];
					return YES;
				}
				NppMacro m = macroIndex < 0 ? currentMacro : NppShortcuts::instance()._macros[macroIndex]._macro;
				int times = [d isChecked: IDC_M_RUN_MULTI] ? std::max(0, [d text: IDC_M_RUN_TIMES].intValue) : -1;
				[weakSelf runMacro: m times: times];
				return YES;
			}
		}
		return NO;
	};
	[dlg enable: IDC_M_RUN_TIMES value: [dlg isChecked: IDC_M_RUN_MULTI]];
	[dlg showModeless];
}

@end
