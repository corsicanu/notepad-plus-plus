// Shortcut Mapper: port of ShortcutMapper (IDD_SHORTCUTMAPPER_DLG) with the
// BabyGrid shown as a table, plus applying shortcuts.xml customizations.

#import "NppShortcutMapper.h"
#import "NppMainWindowInternal.h"
#import "NppMenuBuilder.h"
#import "NppRcDialog.h"
#import "NppLocalization.h"

#include "NppUpstream.h"
#include "ShortcutMapper_rc.h"

#include <functional>
#include <map>
#include <optional>

@interface NppMainWindow (ShortcutMapperHost)
+ (void)installShortcutsXmlItemsIn:(NSMenu*)bar;
@end

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

	NSString* wns(const wchar_t* w)
	{
		if (!w)
			return nil;
		return [[NSString alloc] initWithBytes: w length: wcslen(w) * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding];
	}

	// A Win32 virtual key as a Scintilla Cocoa key code (KeyTranslate).
	int scintillaKeyFor(int vk)
	{
		switch (vk)
		{
			case VK_DOWN: return SCK_DOWN;
			case VK_UP: return SCK_UP;
			case VK_LEFT: return SCK_LEFT;
			case VK_RIGHT: return SCK_RIGHT;
			case VK_HOME: return SCK_HOME;
			case VK_END: return SCK_END;
			case VK_PRIOR: return SCK_PRIOR;
			case VK_NEXT: return SCK_NEXT;
			case VK_DELETE: return SCK_DELETE;
			case VK_INSERT: return SCK_INSERT;
			case VK_ESCAPE: return SCK_ESCAPE;
			case VK_BACK: return SCK_BACK;
			case VK_TAB: return SCK_TAB;
			case VK_RETURN: return SCK_RETURN;
			case VK_ADD: return SCK_ADD;
			case VK_SUBTRACT: return SCK_SUBTRACT;
			case VK_DIVIDE: return SCK_DIVIDE;
			case VK_SPACE: return ' ';
			case VK_OEM_PLUS: return '=';
			case VK_OEM_MINUS: return '-';
			case VK_OEM_COMMA: return ',';
			case VK_OEM_PERIOD: return '.';
			case VK_OEM_1: return ';';
			case VK_OEM_2: return '/';
			case VK_OEM_3: return '`';
			case VK_OEM_4: return '[';
			case VK_OEM_5: return '\\';
			case VK_OEM_6: return ']';
			case VK_OEM_7: return '\'';
		}
		if (vk >= 'A' && vk <= 'Z')
			return vk - 'A' + 'a';
		if (vk >= '0' && vk <= '9')
			return vk;
		if (vk >= VK_F1 && vk <= VK_F24)
			return NSF1FunctionKey + (vk - VK_F1);
		return 0;
	}

	// Ctrl -> Cmd, as for menus.
	int scintillaKeyDefinition(const NppKeyCombo& k)
	{
		int key = scintillaKeyFor(k._key);
		if (!key)
			return 0;
		int mods = (k._isCtrl ? SCMOD_CTRL : 0) | (k._isAlt ? SCMOD_ALT : 0) | (k._isShift ? SCMOD_SHIFT : 0);
		return key | (mods << 16);
	}

	NppKeyCombo comboOf(bool ctrl, bool alt, bool shift, int key)
	{
		NppKeyCombo k;
		k._isCtrl = ctrl;
		k._isAlt = alt;
		k._isShift = shift;
		k._key = key;
		return k;
	}

	bool sameCombo(const NppKeyCombo& a, const NppKeyCombo& b)
	{
		return a._key && a._key == b._key && a._isCtrl == b._isCtrl && a._isAlt == b._isAlt && a._isShift == b._isShift;
	}

	void collectItems(NSMenu* menu, NSString* category, std::map<int, std::pair<NSMenuItem*, NSString*>>& out)
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			if (mi.submenu)
				collectItems(mi.submenu, category ?: mi.title, out);
			else if (mi.tag > 0 && !out.count((int)mi.tag))
				out[(int)mi.tag] = {mi, category ?: @""};
		}
	}

	struct Row
	{
		NSString* name;
		NSString* category;     // main menu: top menu; plugins: plugin
		NppKeyCombo key;
		size_t index;           // into the tab's source list
	};
}

@interface NppShortcutMapper () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation NppShortcutMapper
{
	__weak NppMainWindow* _window;
	NppRcDialog* _dlg;
	NSSegmentedControl* _tabs;
	NSTableView* _table;
	NppShortcutMapperTab _state;
	std::vector<Row> _rows;
}

#pragma mark Applying shortcuts.xml

+ (void)applyMenuShortcuts:(NSMenu*)bar
{
	std::map<int, std::pair<NSMenuItem*, NSString*>> items;
	collectItems(bar, nil, items);
	for (const auto& c : NppShortcuts::instance()._internalCommands)
	{
		// The same command can sit in several menus.
		std::function<void(NSMenu*)> walk = [&](NSMenu* m) {
			for (NSMenuItem* mi in m.itemArray)
			{
				if (mi.submenu)
					walk(mi.submenu);
				else if (mi.tag == c._id)
					[NppMenuBuilder setShortcutOf: mi key: c._keyCombo._key ctrl: c._keyCombo._isCtrl alt: c._keyCombo._isAlt shift: c._keyCombo._isShift];
			}
		};
		walk(bar);
	}
}

// ScintillaKeyMap: the default keys of a customized command are removed,
// the user's keys assigned.
+ (void)applyScintillaKeys:(NSArray*)editors
{
	size_t n = 0;
	const ScintillaKeyDefinition* defs = NppUpstream::scintKeyDefs(n);
	for (const auto& sk : NppShortcuts::instance()._scintillaKeys)
	{
		for (ScintillaView* e in editors)
		{
			for (size_t i = 0; i < n; ++i)
				if (defs[i].functionId == sk._scintId)
					if (int def = scintillaKeyDefinition(comboOf(defs[i].isCtrl, defs[i].isAlt, defs[i].isShift, defs[i].vKey)))
						sci(e, SCI_CLEARCMDKEY, def);
			for (const auto& k : sk._keys)
				if (int def = scintillaKeyDefinition(k))
					sci(e, SCI_ASSIGNCMDKEY, def, sk._scintId);
		}
	}
}

#pragma mark Dialog

+ (void)showForWindow:(NppMainWindow*)window tab:(NppShortcutMapperTab)tab
{
	static NppShortcutMapper* mapper;
	if (!mapper)
		mapper = [[NppShortcutMapper alloc] initWithWindow: window];
	[mapper show: tab];
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_dlg = [[NppRcDialog alloc] initWithRC: @"ShortcutMapper.rc" dialog: @"IDD_SHORTCUTMAPPER_DLG"];
		[NppLocalization applyToDialog: _dlg node: @"ShortcutMapper"];

		_tabs = (NSSegmentedControl*)[_dlg item: IDC_BABYGRID_TABBAR];
		NSArray* tabNames = @[@"Main menu", @"Macros", @"Run commands", @"Plugin commands", @"Scintilla commands"];
		_tabs.segmentCount = tabNames.count;
		for (NSUInteger i = 0; i < tabNames.count; ++i)
			[_tabs setLabel: tabNames[i] forSegment: i];
		[_tabs sizeToFit];

		// The grid (BabyGrid) fills the space between the tabs and the info box.
		NSView* info = [_dlg item: IDC_BABYGRID_INFO];
		NSView* content = _dlg.window.contentView;
		CGFloat top = NSMaxY(_tabs.frame) + 6, bottom = info.frame.origin.y - 6;
		if (!content.isFlipped)
		{
			top = _tabs.frame.origin.y - 6;
			bottom = NSMaxY(info.frame) + 6;
		}
		NSRect gridFrame = content.isFlipped
			? NSMakeRect(info.frame.origin.x, top, info.frame.size.width, bottom - top)
			: NSMakeRect(info.frame.origin.x, bottom, info.frame.size.width, top - bottom);

		_table = [[NSTableView alloc] init];
		_table.usesAlternatingRowBackgroundColors = YES;
		_table.allowsMultipleSelection = NO;
		_table.rowHeight = 18;
		_table.dataSource = self;
		_table.delegate = self;
		_table.target = self;
		_table.doubleAction = @selector(modify:);
		NSScrollView* sv = [[NSScrollView alloc] initWithFrame: gridFrame];
		sv.documentView = _table;
		sv.hasVerticalScroller = YES;
		sv.borderType = NSBezelBorder;
		sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[content addSubview: sv];

		__weak NppShortcutMapper* weakSelf = self;
		_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) { return [weakSelf command: cid]; };
	}
	return self;
}

- (void)show:(NppShortcutMapperTab)tab
{
	_state = tab;
	_tabs.selectedSegment = tab;
	[self fillOut];
	[_dlg showModeless];
}

- (void)setColumns
{
	while (_table.tableColumns.count)
		[_table removeTableColumn: _table.tableColumns.lastObject];
	NSMutableArray* cols = [NSMutableArray arrayWithObjects: @"Name", @"Shortcut", nil];
	if (_state == NppShortcutMapperMainMenu)
		[cols addObject: @"Category"];
	if (_state == NppShortcutMapperPluginCommands)
		[cols addObject: @"Plugin"];
	CGFloat w = _table.enclosingScrollView.contentSize.width;
	for (NSUInteger i = 0; i < cols.count; ++i)
	{
		NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier: [NSString stringWithFormat: @"%lu", (unsigned long)i]];
		c.title = cols[i];
		c.width = i == 0 ? w * 0.5 : (w * 0.5) / (cols.count - 1) - 4;
		[_table addTableColumn: c];
	}
}

// ShortcutMapper::fillOutBabyGrid
- (void)fillOut
{
	_rows.clear();
	NppShortcuts& sc = NppShortcuts::instance();
	switch (_state)
	{
		case NppShortcutMapperMainMenu:
		{
			std::map<int, std::pair<NSMenuItem*, NSString*>> items;
			collectItems(NSApp.mainMenu, nil, items);
			size_t n = 0;
			const WinMenuKeyDefinition* defs = NppUpstream::winKeyDefs(n);
			for (size_t i = 0; i < n; ++i)
			{
				const auto& d = defs[i];
				auto it = items.find(d.functionId);
				NSString* name = wns(d.specialName);
				if (!name.length && it != items.end())
					name = it->second.first.title;
				if (!name.length)
					continue;
				name = [NppMenuBuilder macTitle: name command: d.functionId];
				NppKeyCombo key = comboOf(d.isCtrl, d.isAlt, d.isShift, d.vKey);
				for (const auto& c : sc._internalCommands)
					if (c._id == d.functionId)
						key = c._keyCombo;
				NSString* category = it != items.end() ? [NppMenuBuilder stripMnemonic: it->second.second] : @"";
				_rows.push_back({name, category, key, i});
			}
			break;
		}
		case NppShortcutMapperMacros:
			for (size_t i = 0; i < sc._macros.size(); ++i)
				_rows.push_back({ns(sc._macros[i]._name), nil, sc._macros[i]._keyCombo, i});
			break;
		case NppShortcutMapperRunCommands:
			for (size_t i = 0; i < sc._userCommands.size(); ++i)
				_rows.push_back({ns(sc._userCommands[i]._name), nil, sc._userCommands[i]._keyCombo, i});
			break;
		case NppShortcutMapperPluginCommands:
			break;   // Win32 plugins don't run on macOS
		case NppShortcutMapperScintilla:
		{
			size_t n = 0;
			const ScintillaKeyDefinition* defs = NppUpstream::scintKeyDefs(n);
			for (size_t i = 0; i < n; ++i)
			{
				const auto& d = defs[i];
				NppKeyCombo key = comboOf(d.isCtrl, d.isAlt, d.isShift, d.vKey);
				for (const auto& sk : sc._scintillaKeys)
					if (sk._scintId == d.functionId)
						key = sk._keys.empty() ? NppKeyCombo() : sk._keys[0];
				_rows.push_back({wns(d.name), nil, key, i});
			}
			break;
		}
	}

	// IDC_BABYGRID_FILTER: every word must be in the name, shortcut or category.
	NSArray* words = [[_dlg text: IDC_BABYGRID_FILTER] componentsSeparatedByString: @" "];
	std::vector<Row> filtered;
	for (const Row& r : _rows)
	{
		NSString* hay = [NSString stringWithFormat: @"%@ %@ %@", r.name, ns(NppShortcuts::keyComboString(r.key)), r.category ?: @""];
		BOOL ok = YES;
		for (NSString* w in words)
			if (w.length && [hay rangeOfString: w options: NSCaseInsensitiveSearch].location == NSNotFound)
				ok = NO;
		if (ok)
			filtered.push_back(r);
	}
	_rows = filtered;

	[self setColumns];
	[_table reloadData];
	BOOL editable = _state != NppShortcutMapperPluginCommands;
	[_dlg enable: IDM_BABYGRID_MODIFY value: editable];
	[_dlg enable: IDM_BABYGRID_CLEAR value: editable];
	[_dlg enable: IDM_BABYGRID_DELETE value: _state == NppShortcutMapperMacros || _state == NppShortcutMapperRunCommands];
	[self updateInfo];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t
{
	return _rows.size();
}

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
	NSTextField* f = [t makeViewWithIdentifier: @"cell" owner: nil];
	if (!f)
	{
		f = [NSTextField labelWithString: @""];
		f.identifier = @"cell";
		f.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
		f.lineBreakMode = NSLineBreakByTruncatingTail;
	}
	const Row& r = _rows[row];
	NSInteger c = col.identifier.integerValue;
	f.stringValue = c == 0 ? r.name : c == 1 ? ns(NppShortcuts::keyComboString(r.key)) : (r.category ?: @"");
	// Conflicting shortcuts are marked, as BabyGrid's marker does.
	f.textColor = [self conflictsFor: r].length ? NSColor.systemRedColor : NSColor.labelColor;
	return f;
}

- (void)tableViewSelectionDidChange:(NSNotification*)n
{
	[self updateInfo];
}

#pragma mark Conflicts (ShortcutMapper::findKeyConflicts)

- (NSString*)conflictsFor:(const Row&)row
{
	if (!row.key._key)
		return @"";
	NSMutableArray* lines = [NSMutableArray array];
	NppShortcuts& sc = NppShortcuts::instance();
	auto check = [&](NppShortcutMapperTab tab, size_t index, NSString* tabName, NSString* name, const NppKeyCombo& k) {
		if (tab == _state && index == row.index)
			return;
		if (sameCombo(k, row.key))
			[lines addObject: [NSString stringWithFormat: @"%@  |  %lu   %@  ( %s )", tabName, (unsigned long)index + 1, name,
			                   NppShortcuts::keyComboString(k).c_str()]];
	};
	size_t n = 0;
	const WinMenuKeyDefinition* menuDefs = NppUpstream::winKeyDefs(n);
	for (size_t i = 0; i < n; ++i)
	{
		NppKeyCombo k = comboOf(menuDefs[i].isCtrl, menuDefs[i].isAlt, menuDefs[i].isShift, menuDefs[i].vKey);
		for (const auto& c : sc._internalCommands)
			if (c._id == menuDefs[i].functionId)
				k = c._keyCombo;
		check(NppShortcutMapperMainMenu, i, @"Main menu", wns(menuDefs[i].specialName) ?: [NSString stringWithFormat: @"%d", menuDefs[i].functionId], k);
	}
	for (size_t i = 0; i < sc._macros.size(); ++i)
		check(NppShortcutMapperMacros, i, @"Macros", ns(sc._macros[i]._name), sc._macros[i]._keyCombo);
	for (size_t i = 0; i < sc._userCommands.size(); ++i)
		check(NppShortcutMapperRunCommands, i, @"Run commands", ns(sc._userCommands[i]._name), sc._userCommands[i]._keyCombo);
	const ScintillaKeyDefinition* sciDefs = NppUpstream::scintKeyDefs(n);
	for (size_t i = 0; i < n; ++i)
	{
		NppKeyCombo k = comboOf(sciDefs[i].isCtrl, sciDefs[i].isAlt, sciDefs[i].isShift, sciDefs[i].vKey);
		for (const auto& s : sc._scintillaKeys)
			if (s._scintId == sciDefs[i].functionId)
				k = s._keys.empty() ? NppKeyCombo() : s._keys[0];
		check(NppShortcutMapperScintilla, i, @"Scintilla commands", wns(sciDefs[i].name), k);
	}
	return [lines componentsJoinedByString: @"\n"];
}

- (void)updateInfo
{
	NSInteger row = _table.selectedRow;
	NSString* info = @"";
	if (row >= 0 && row < (NSInteger)_rows.size())
	{
		info = [self conflictsFor: _rows[row]];
		if (!info.length)
			info = @"No shortcut conflicts for this item.";
	}
	[_dlg setText: IDC_BABYGRID_INFO value: info];
}

#pragma mark Commands

- (BOOL)command:(int)cid
{
	switch (cid)
	{
		case IDC_BABYGRID_TABBAR:
			_state = (NppShortcutMapperTab)_tabs.selectedSegment;
			[self fillOut];
			return YES;
		case IDC_BABYGRID_FILTER:
			[self fillOut];
			return YES;
		case IDC_BABYGRID_FILTER_CLEAR:
			[_dlg setText: IDC_BABYGRID_FILTER value: @""];
			[self fillOut];
			return YES;
		case IDM_BABYGRID_MODIFY: [self modify: nil]; return YES;
		case IDM_BABYGRID_CLEAR: [self clear]; return YES;
		case IDM_BABYGRID_DELETE: [self deleteItem]; return YES;
	}
	return NO;
}

- (void)modify:(id)sender
{
	NSInteger row = _table.selectedRow;
	if (row < 0 || _state == NppShortcutMapperPluginCommands)
		return;
	Row r = _rows[row];
	NppShortcuts& sc = NppShortcuts::instance();
	NppShortcutEntry e;
	e._name = r.name.UTF8String ?: "";
	e._keyCombo = r.key;
	BOOL nameEditable = _state == NppShortcutMapperMacros || _state == NppShortcutMapperRunCommands;
	if (!nppShortcutDialog(e, nil, nameEditable))
		return;
	[self setKey: e._keyCombo name: e._name forRow: r];
	(void)sc;
}

- (void)clear
{
	NSInteger row = _table.selectedRow;
	if (row < 0)
		return;
	Row r = _rows[row];
	[self setKey: NppKeyCombo() name: r.name.UTF8String ?: "" forRow: r];
}

- (void)setKey:(const NppKeyCombo&)key name:(const std::string&)name forRow:(const Row&)r
{
	NppShortcuts& sc = NppShortcuts::instance();
	switch (_state)
	{
		case NppShortcutMapperMainMenu:
		{
			size_t n = 0;
			int id = NppUpstream::winKeyDefs(n)[r.index].functionId;
			bool found = false;
			for (auto& c : sc._internalCommands)
				if (c._id == id)
				{
					c._keyCombo = key;
					found = true;
				}
			if (!found)
				sc._internalCommands.push_back({id, key});
			break;
		}
		case NppShortcutMapperMacros:
			sc._macros[r.index]._name = name;
			sc._macros[r.index]._keyCombo = key;
			break;
		case NppShortcutMapperRunCommands:
			sc._userCommands[r.index]._name = name;
			sc._userCommands[r.index]._keyCombo = key;
			break;
		case NppShortcutMapperScintilla:
		{
			size_t n = 0;
			const ScintillaKeyDefinition& d = NppUpstream::scintKeyDefs(n)[r.index];
			NppScintillaKey* sk = nullptr;
			for (auto& s : sc._scintillaKeys)
				if (s._scintId == d.functionId)
					sk = &s;
			if (!sk)
			{
				sc._scintillaKeys.push_back({d.functionId, d.redirFunctionId, {}});
				sk = &sc._scintillaKeys.back();
			}
			sk->_keys.clear();
			if (key._key)
				sk->_keys.push_back(key);
			break;
		}
		default:
			return;
	}
	[self commit];
}

- (void)deleteItem
{
	NSInteger row = _table.selectedRow;
	if (row < 0)
		return;
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = @"Are you sure you want to delete this shortcut?";
	[a addButtonWithTitle: @"OK"];
	[a addButtonWithTitle: @"Cancel"];
	if ([a runModal] != NSAlertFirstButtonReturn)
		return;
	NppShortcuts& sc = NppShortcuts::instance();
	size_t i = _rows[row].index;
	if (_state == NppShortcutMapperMacros && i < sc._macros.size())
		sc._macros.erase(sc._macros.begin() + i);
	else if (_state == NppShortcutMapperRunCommands && i < sc._userCommands.size())
		sc._userCommands.erase(sc._userCommands.begin() + i);
	[self commit];
}

// Saved right away; menus and editors pick the change up.
- (void)commit
{
	NppShortcuts::instance().save();
	[NppMainWindow installShortcutsXmlItemsIn: NSApp.mainMenu];
	[NppShortcutMapper applyMenuShortcuts: NSApp.mainMenu];
	if (NppMainWindow* w = _window)
		[NppShortcutMapper applyScintillaKeys: [w allEditors]];
	NSInteger sel = _table.selectedRow;
	[self fillOut];
	if (sel >= 0 && sel < (NSInteger)_rows.size())
		[_table selectRowIndexes: [NSIndexSet indexSetWithIndex: sel] byExtendingSelection: NO];
}

@end
