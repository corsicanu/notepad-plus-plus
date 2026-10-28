// Docking panels: Clipboard History (ClipboardHistoryPanel), Character Panel
// (AnsiCharPanel) and Document List (VerticalFileSwitcher).

#import "NppPanels.h"
#import "NppMainWindowInternal.h"
#import "NppPreferences.h"
#import "NppWorkspacePanels.h"

#include "NppAsciiTable.h"
#include "NppSettings.h"
#include "NppUpstream.h"

#include <unordered_map>

NSNotificationName const NppDocumentsChangedNotification = @"NppDocumentsChangedNotification";

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	NSScrollView* scrolled(NSTableView* table)
	{
		NSScrollView* sv = [[NSScrollView alloc] init];
		sv.documentView = table;
		sv.hasVerticalScroller = YES;
		sv.hasHorizontalScroller = YES;
		sv.autohidesScrollers = YES;
		return sv;
	}

	NSTableView* makeTable(NSArray<NSString*>* columns, NSArray<NSNumber*>* widths, id owner)
	{
		NSTableView* t = [[NSTableView alloc] init];
		t.usesAlternatingRowBackgroundColors = NO;
		t.allowsMultipleSelection = NO;
		t.style = NSTableViewStylePlain;
		t.rowHeight = 18;
		for (NSUInteger i = 0; i < columns.count; ++i)
		{
			NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier: [NSString stringWithFormat: @"%lu", (unsigned long)i]];
			c.title = columns[i];
			c.width = widths[i].doubleValue;
			[t addTableColumn: c];
		}
		t.dataSource = owner;
		t.delegate = owner;
		t.target = owner;
		return t;
	}

	NSTextField* cellText(NSTableView* t, NSString* text)
	{
		NSTextField* f = [t makeViewWithIdentifier: @"cell" owner: nil];
		if (!f)
		{
			f = [NSTextField labelWithString: @""];
			f.identifier = @"cell";
			f.lineBreakMode = NSLineBreakByTruncatingTail;
			f.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
		}
		f.stringValue = text ?: @"";
		return f;
	}

	// AnsiCharPanel::insertString / ClipboardHistoryPanel::onDoubleClick.
	void insertIntoEditor(NppMainWindow* w, const std::string& utf8)
	{
		ScintillaView* e = w.editor;
		sci(e, SCI_REPLACESEL, 0, reinterpret_cast<sptr_t>(""));
		sci(e, SCI_ADDTEXT, utf8.size(), reinterpret_cast<sptr_t>(utf8.data()));
		[w.window makeFirstResponder: e.content];
	}
}

#pragma mark - Clipboard History

@implementation NppClipboardHistoryPanel
{
	__weak NppMainWindow* _window;
	NSTableView* _table;
	NSScrollView* _scroll;
	NSMutableArray<NSString*>* _entries;    // most recent first
	NSInteger _changeCount;
	NSTimer* _timer;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_entries = [NSMutableArray array];
		_table = makeTable(@[@""], @[@240], self);
		_table.headerView = nil;
		_table.doubleAction = @selector(doubleClicked:);
		_scroll = scrolled(_table);
		// Upstream joins the clipboard viewer chain when the panel is created
		// and keeps recording while it exists, shown or not.
		_changeCount = NSPasteboard.generalPasteboard.changeCount;
		[self captureClipboard];
		_timer = [NSTimer scheduledTimerWithTimeInterval: 0.5 target: self selector: @selector(poll:) userInfo: nil repeats: YES];
	}
	return self;
}

- (NSString*)title { return @"Clipboard History"; }
- (NSView*)view { return _scroll; }

- (void)poll:(NSTimer*)t
{
	NSInteger cc = NSPasteboard.generalPasteboard.changeCount;
	if (cc == _changeCount)
		return;
	_changeCount = cc;
	[self captureClipboard];
}

// addToClipboadHistory: an entry already present moves to the top.
- (void)captureClipboard
{
	NSString* s = [NSPasteboard.generalPasteboard stringForType: NSPasteboardTypeString];
	if (!s.length)
		return;
	NSUInteger i = [_entries indexOfObject: s];
	if (i == 0)
		return;
	if (i != NSNotFound)
		[_entries removeObjectAtIndex: i];
	[_entries insertObject: s atIndex: 0];
	[_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t
{
	return _entries.count;
}

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
	// getDisplayStr: one line, truncated to MAX_PATH - 3 characters.
	static const NSUInteger maxLen = 260 - 3;
	NSString* s = _entries[row];
	BOOL truncated = s.length > maxLen;
	if (truncated)
		s = [[s substringToIndex: maxLen] stringByAppendingString: @"..."];
	s = [[s componentsSeparatedByCharactersInSet: NSCharacterSet.newlineCharacterSet] componentsJoinedByString: @" "];
	return cellText(t, s);
}

- (void)doubleClicked:(id)sender
{
	NSInteger row = _table.clickedRow;
	if (row < 0 || row >= (NSInteger)_entries.count || !_window)
		return;
	insertIntoEditor(_window, _entries[row].UTF8String ?: "");
}

@end

#pragma mark - Character Panel

@implementation NppCharacterPanel
{
	__weak NppMainWindow* _window;
	NSTableView* _table;
	NSScrollView* _scroll;
	std::vector<std::vector<std::wstring>> _rows;
	int _codepage;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_codepage = -2;
		_table = makeTable(@[@"Value", @"Hex", @"Character", @"HTML Name", @"HTML Decimal", @"HTML Hexadecimal"],
		                   @[@45, @45, @70, @90, @100, @120], self);
		_table.doubleAction = @selector(doubleClicked:);
		_scroll = scrolled(_table);
		[self panelDidShow];
	}
	return self;
}

- (NSString*)title { return @"ASCII Codes Insertion Panel"; }
- (NSView*)view { return _scroll; }

// The table follows the current document's codepage (AsciiListView::resetValues).
- (void)panelDidShow
{
	int cp = _window.currentBuffer.encoding;
	if (cp == -1)
		cp = 0;
	if (cp == _codepage)
		return;
	_codepage = cp;
	_rows = nppAsciiTable(cp);
	[_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t
{
	return _rows.size();
}

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
	NSUInteger c = col.identifier.integerValue;
	const auto& r = _rows[row];
	if (c >= r.size())
		return cellText(t, @"");
	const std::wstring& w = r[c];
	NSString* s = [[NSString alloc] initWithBytes: w.data() length: w.size() * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding];
	return cellText(t, s);
}

// Double click: the Character column inserts the character, the others the cell text.
- (void)doubleClicked:(id)sender
{
	NSInteger row = _table.clickedRow, col = _table.clickedColumn;
	if (row < 0 || !_window)
		return;
	if (col == 2)
		[self insertCharacter: row];
	else if (col >= 0)
	{
		const std::wstring& w = _rows[row][col];
		NSString* s = [[NSString alloc] initWithBytes: w.data() length: w.size() * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding];
		insertIntoEditor(_window, s.UTF8String ?: "");
	}
}

- (void)keyDown:(NSEvent*)e
{
	if (e.keyCode == 36 && _table.selectedRow >= 0)   // Return
		[self insertCharacter: _table.selectedRow];
}

// AnsiCharPanel::insertChar: the byte in the document's codepage, as UTF-8.
- (void)insertCharacter:(NSInteger)value
{
	unsigned char byte = static_cast<unsigned char>(value);
	std::string out;
	if (byte < 128)
		out.assign(1, static_cast<char>(byte));
	else
	{
		CFStringEncoding enc = CFStringConvertWindowsCodepageToEncoding(_codepage ? _codepage : 1252);
		NSString* s = (__bridge_transfer NSString*)CFStringCreateWithBytes(nullptr, &byte, 1, enc, false);
		out = s.UTF8String ?: "";
	}
	insertIntoEditor(_window, out);
}

@end

#pragma mark - Document List

@implementation NppDocumentListPanel
{
	__weak NppMainWindow* _window;
	NSTableView* _table;
	NSScrollView* _scroll;
	NSArray* _rows;           // NppBuffer, or NSNull for the separator between views
	NSArray<NSNumber*>* _views;
	BOOL _ext, _path;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_scroll = [[NSScrollView alloc] init];
		_scroll.hasVerticalScroller = YES;
		_scroll.autohidesScrollers = YES;
		[self buildTable];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(reload) name: NppDocumentsChangedNotification object: nil];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(settingsChanged) name: NppSettingsChangedNotification object: nil];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver: self];
}

- (NSString*)title { return @"Document List"; }
- (NSView*)view { return _scroll; }

- (void)buildTable
{
	const NppSettings& s = NppSettings::instance();
	_ext = !s._fileSwitcherWithoutExtColumn;
	_path = !s._fileSwitcherWithoutPathColumn;
	NSMutableArray* cols = [NSMutableArray arrayWithObject: @"Name"];
	NSMutableArray* widths = [NSMutableArray arrayWithObject: @160];
	if (_ext)
	{
		[cols addObject: @"Ext."];
		[widths addObject: @50];
	}
	if (_path)
	{
		[cols addObject: @"Path"];
		[widths addObject: @200];
	}
	_table = makeTable(cols, widths, self);
	_table.action = @selector(clicked:);
	_table.menu = [[NSMenu alloc] init];
	_table.menu.delegate = (id<NSMenuDelegate>)self;
	_scroll.documentView = _table;
	[self reload];
}

- (void)settingsChanged
{
	const NppSettings& s = NppSettings::instance();
	if (_ext != !s._fileSwitcherWithoutExtColumn || _path != !s._fileSwitcherWithoutPathColumn)
		[self buildTable];
	else
		[self reload];
}

- (void)panelDidShow
{
	[self reload];
}

// Main view documents, then the sub view's (VerticalFileSwitcher groups).
- (void)reload
{
	NppMainWindow* w = _window;
	if (!w)
		return;
	NSMutableArray* rows = [NSMutableArray array];
	NSMutableArray* views = [NSMutableArray array];
	NSArray<NppBuffer*>* main = [w buffersOfView: 0];
	NSArray<NppBuffer*>* sub = [w buffersOfView: 1];
	for (NppBuffer* b in main)
	{
		[rows addObject: b];
		[views addObject: @0];
	}
	if (sub.count)
	{
		if (!NppSettings::instance()._fileSwitcherDisableListViewGroups && main.count)
		{
			[rows addObject: NSNull.null];
			[views addObject: @-1];
		}
		for (NppBuffer* b in sub)
		{
			[rows addObject: b];
			[views addObject: @1];
		}
	}
	_rows = rows;
	_views = views;
	[_table reloadData];

	// Select the current document of the active view.
	NppBuffer* cur = w.currentBuffer;
	int active = [w activeView];
	for (NSUInteger i = 0; i < _rows.count; ++i)
		if (_rows[i] == cur && _views[i].intValue == active)
		{
			[_table selectRowIndexes: [NSIndexSet indexSetWithIndex: i] byExtendingSelection: NO];
			[_table scrollRowToVisible: i];
		}
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t
{
	return _rows.count;
}

- (BOOL)tableView:(NSTableView*)t isGroupRow:(NSInteger)row
{
	return _rows[row] == NSNull.null;
}

- (BOOL)tableView:(NSTableView*)t shouldSelectRow:(NSInteger)row
{
	return _rows[row] != NSNull.null;
}

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
	if (_rows[row] == NSNull.null)
		return col ? nil : cellText(t, @"");
	NppBuffer* b = _rows[row];
	NSString* name = b.displayName;
	NSInteger c = col.identifier.integerValue;
	if (c == 0)
	{
		NSTableCellView* v = [t makeViewWithIdentifier: @"name" owner: nil];
		if (!v)
		{
			v = [[NSTableCellView alloc] init];
			v.identifier = @"name";
			NSImageView* iv = [NSImageView imageViewWithImage: [NSImage imageWithSize: NSMakeSize(14, 14) flipped: NO drawingHandler: ^BOOL(NSRect) { return YES; }]];
			NSTextField* tf = [NSTextField labelWithString: @""];
			tf.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
			tf.lineBreakMode = NSLineBreakByTruncatingTail;
			for (NSView* sv in @[iv, tf])
			{
				sv.translatesAutoresizingMaskIntoConstraints = NO;
				[v addSubview: sv];
			}
			v.imageView = iv;
			v.textField = tf;
			[NSLayoutConstraint activateConstraints: @[
				[iv.leadingAnchor constraintEqualToAnchor: v.leadingAnchor constant: 2],
				[iv.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
				[iv.widthAnchor constraintEqualToConstant: 14],
				[iv.heightAnchor constraintEqualToConstant: 14],
				[tf.leadingAnchor constraintEqualToAnchor: iv.trailingAnchor constant: 4],
				[tf.trailingAnchor constraintEqualToAnchor: v.trailingAnchor],
				[tf.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
			]];
		}
		v.textField.stringValue = name;
		// Same states as the tab icons: saved, unsaved, read-only.
		v.imageView.image = [_window tabStateImageFor: b];
		return v;
	}
	BOOL isExt = _ext && c == 1;
	if (isExt)
		return cellText(t, name.pathExtension.length ? [@"." stringByAppendingString: name.pathExtension] : @"");
	return cellText(t, b.path ? [b.path.stringByDeletingLastPathComponent stringByAppendingString: @"/"] : @"");
}

- (void)clicked:(id)sender
{
	NSInteger row = _table.clickedRow;
	if (row < 0 || _rows[row] == NSNull.null || !_window)
		return;
	[_window activateBuffer: _rows[row] inView: _views[row].intValue];
}

// Right click: the document becomes current, then the tab context menu applies to it.
- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSInteger row = _table.clickedRow;
	if (row < 0 || _rows[row] == NSNull.null || !_window)
		return;
	[_window activateBuffer: _rows[row] inView: _views[row].intValue];
	for (NSMenuItem* mi in [_window documentListContextMenu].itemArray)
		[menu addItem: [mi copy]];
}

@end

#pragma mark - Panel commands

typedef void (^NppCommandHandler)(NppMainWindow* w);

@implementation NppMainWindow (Panels)

// Creates the panel on first use (Notepad_plus::launch*Panel), with upstream's
// default side.
- (id<NppDockPanel>)panelForCommand:(int)cmd
{
	NppDockManager* dock = self.dock;
	if (id<NppDockPanel> p = [dock panelForCommand: cmd])
		return p;
	id<NppDockPanel> p = nil;
	NppDockSide side = NppDockRight;
	switch (cmd)
	{
		case IDM_EDIT_CLIPBOARDHISTORY_PANEL: p = [[NppClipboardHistoryPanel alloc] initWithWindow: self]; break;
		case IDM_EDIT_CHAR_PANEL: p = [[NppCharacterPanel alloc] initWithWindow: self]; break;
		case IDM_VIEW_DOCLIST: p = [[NppDocumentListPanel alloc] initWithWindow: self]; side = NppDockLeft; break;
		case IDM_VIEW_FILEBROWSER: p = [[NppFolderAsWorkspacePanel alloc] initWithWindow: self]; side = NppDockLeft; break;
		case IDM_VIEW_DOC_MAP: p = [[NppDocumentMapPanel alloc] initWithWindow: self]; break;
		default: return nil;
	}
	[dock addPanel: p forCommand: cmd side: side];
	return p;
}

- (void)togglePanel:(int)cmd
{
	if ([self panelForCommand: cmd])
		[self.dock togglePanel: cmd];
}

// IDM_VIEW_SWITCHTO_*: show the panel and give it the keyboard focus.
- (void)focusPanel:(int)cmd
{
	id<NppDockPanel> p = [self panelForCommand: cmd];
	if (!p)
		return;
	[self.dock showPanel: cmd];
	NSView* v = p.view;
	if ([v isKindOfClass: NSScrollView.class])
		v = ((NSScrollView*)v).documentView;
	[self.window makeFirstResponder: v];
}

- (BOOL)isPanelShown:(int)cmd
{
	return [self.dock isPanelVisible: cmd];
}

+ (void)registerPanelCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	for (int cmd : {IDM_EDIT_CLIPBOARDHISTORY_PANEL, IDM_EDIT_CHAR_PANEL, IDM_VIEW_DOCLIST, IDM_VIEW_FILEBROWSER, IDM_VIEW_DOC_MAP})
		t[cmd] = ^(NppMainWindow* w) { [w togglePanel: cmd]; };
	t[IDM_VIEW_SWITCHTO_DOCLIST] = ^(NppMainWindow* w) { [w focusPanel: IDM_VIEW_DOCLIST]; };
	t[IDM_VIEW_SWITCHTO_FILEBROWSER] = ^(NppMainWindow* w) { [w focusPanel: IDM_VIEW_FILEBROWSER]; };
	// File > Open Folder as Workspace...
	t[IDM_FILE_OPENFOLDERASWORKSPACE] = ^(NppMainWindow* w) {
		NSOpenPanel* p = [NSOpenPanel openPanel];
		p.canChooseDirectories = YES;
		p.canChooseFiles = NO;
		p.message = @"Select a folder to add in Folder as Workspace panel";
		if ([p runModal] != NSModalResponseOK)
			return;
		NppFolderAsWorkspacePanel* fb = (NppFolderAsWorkspacePanel*)[w panelForCommand: IDM_VIEW_FILEBROWSER];
		[fb addRoot: p.URL.path];
		[w.dock showPanel: IDM_VIEW_FILEBROWSER];
	};
}

@end
