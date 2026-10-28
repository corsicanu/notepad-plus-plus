// Function List panel: port of FunctionListPanel on top of upstream's
// FunctionParsersManager (functionParser.cpp, compiled unchanged) and its
// functionList/*.xml parser rules.

#import "NppFunctionList.h"
#import "NppMainWindowInternal.h"
#import "NppPanels.h"

#include "../compat/shim/NppXml.h"
#include "functionParser.h"
#include "../compat/shim/ScintillaEditView.h"
#include "../compat/shim/Common.h"

#include "LangManager.h"
#include "NppConfig.h"
#include "NppSettings.h"

#include <memory>

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	enum ItemKind { kRoot, kNode, kLeaf };
}

@interface NppFuncItem : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic) ItemKind kind;
@property (nonatomic) long pos;           // -1 for root / nodes
@property (nonatomic, strong) NSMutableArray<NppFuncItem*>* children;
@end

@implementation NppFuncItem
@end

@implementation NppFunctionListPanel
{
	__weak NppMainWindow* _window;
	NSView* _root;
	NSSearchField* _search;
	NSButton* _sortButton;
	NSOutlineView* _tree;
	FunctionParsersManager _parsers;
	std::unique_ptr<ScintillaEditView> _editView;
	ScintillaEditView* _pEditView;
	NppFuncItem* _full;                    // parse result in document order
	NppFuncItem* _shown;                   // sorted / filtered copy on screen
	BOOL _visible;
	__weak NppBuffer* _lastBuffer;
	BOOL _lastDirty;
	const NppLang* _lastLang;
	// Per document: search text and sort state (addInStateArray).
	NSMutableDictionary<NSString*, NSDictionary*>* _states;
	long _findLine, _findEndLine;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_states = [NSMutableDictionary dictionary];
		_findLine = _findEndLine = -1;

		// FunctionListPanel::init: user rules first, then the bundled ones.
		std::string user = NppConfig::instance().userDir() + "/functionList";
		std::string installed = std::string(NSBundle.mainBundle.resourcePath.fileSystemRepresentation) + "/functionList";
		_parsers.init(string2wstring(user), string2wstring(installed), &_pEditView);

		_search = [[NSSearchField alloc] init];
		_search.placeholderString = @"";
		_search.controlSize = NSControlSizeSmall;
		_search.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
		_search.target = self;
		_search.action = @selector(searchChanged:);
		_search.sendsSearchStringImmediately = YES;

		_sortButton = [NSButton buttonWithImage: [NSImage imageWithSystemSymbolName: @"textformat.abc" accessibilityDescription: @"Sort"]
		                                 target: self action: @selector(toggleSort:)];
		_sortButton.buttonType = NSButtonTypePushOnPushOff;
		_sortButton.bezelStyle = NSBezelStyleTexturedRounded;
		_sortButton.toolTip = @"Sort";
		NSButton* reload = [NSButton buttonWithImage: [NSImage imageWithSystemSymbolName: @"arrow.clockwise" accessibilityDescription: @"Reload"]
		                                      target: self action: @selector(reloadClicked:)];
		reload.bezelStyle = NSBezelStyleTexturedRounded;
		reload.toolTip = @"Reload";
		NSButton* prefs = [NSButton buttonWithImage: [NSImage imageWithSystemSymbolName: @"gearshape" accessibilityDescription: @"Preferences"]
		                                     target: self action: @selector(showPreferences:)];
		prefs.bezelStyle = NSBezelStyleTexturedRounded;
		prefs.toolTip = @"Preferences";

		NSStackView* bar = [NSStackView stackViewWithViews: @[_search, _sortButton, reload, prefs]];
		bar.spacing = 4;
		bar.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);
		[_search setContentHuggingPriority: 1 forOrientation: NSLayoutConstraintOrientationHorizontal];
		bar.translatesAutoresizingMaskIntoConstraints = NO;

		_tree = [[NSOutlineView alloc] init];
		NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier: @"name"];
		[_tree addTableColumn: col];
		_tree.outlineTableColumn = col;
		_tree.headerView = nil;
		_tree.rowHeight = 18;
		_tree.dataSource = self;
		_tree.delegate = self;
		_tree.target = self;
		_tree.doubleAction = @selector(openSelection:);
		_tree.action = @selector(openSelection:);

		NSScrollView* sv = [[NSScrollView alloc] init];
		sv.documentView = _tree;
		sv.hasVerticalScroller = YES;
		sv.autohidesScrollers = YES;
		sv.translatesAutoresizingMaskIntoConstraints = NO;

		_root = [[NSView alloc] init];
		[_root addSubview: bar];
		[_root addSubview: sv];
		[NSLayoutConstraint activateConstraints: @[
			[bar.topAnchor constraintEqualToAnchor: _root.topAnchor],
			[bar.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[bar.trailingAnchor constraintEqualToAnchor: _root.trailingAnchor],
			[bar.heightAnchor constraintEqualToConstant: 26],
			[sv.topAnchor constraintEqualToAnchor: bar.bottomAnchor constant: 2],
			[sv.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[sv.trailingAnchor constraintEqualToAnchor: _root.trailingAnchor],
			[sv.bottomAnchor constraintEqualToAnchor: _root.bottomAnchor],
		]];

		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(documentsChanged) name: NppDocumentsChangedNotification object: nil];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver: self];
}

- (NSString*)title { return @"Function List"; }
- (NSView*)view { return _root; }

- (void)panelDidShow
{
	_visible = YES;
	[self reload];
}

- (void)panelDidHide
{
	_visible = NO;
}

// Notepad_plus reloads on buffer activation, language change and save.
- (void)documentsChanged
{
	if (!_visible)
		return;
	NppBuffer* b = _window.currentBuffer;
	BOOL saved = b == _lastBuffer && _lastDirty && !b.dirty;
	if (b != _lastBuffer || b.lang != _lastLang || saved)
		[self reload];
	_lastDirty = b.dirty;
}

#pragma mark Parsing (FunctionListPanel::reload)

- (void)reload
{
	NppMainWindow* w = _window;
	NppBuffer* b = w.currentBuffer;
	if (!w || !b)
		return;

	// Remember the previous document's search / sort state.
	if (_lastBuffer && _full)
		_states[_lastBuffer.path ?: _lastBuffer.displayName] = @{@"search": _search.stringValue, @"sort": @(_sortButton.state == NSControlStateValueOn)};

	_lastBuffer = b;
	_lastDirty = b.dirty;
	_lastLang = b.lang;
	_findLine = _findEndLine = -1;

	ScintillaView* e = w.editor;
	auto fn = reinterpret_cast<ScintillaEditView::DirectFn>(sci(e, SCI_GETDIRECTFUNCTION));
	_editView = std::make_unique<ScintillaEditView>(fn, sci(e, SCI_GETDIRECTPOINTER));
	_pEditView = _editView.get();

	int langID = b.lang ? LangManager::instance().langTypeOf(b.lang) : L_TEXT;
	if (langID == L_JS_EMBEDDED)
		langID = L_JAVASCRIPT;
	NSString* name = b.displayName;
	std::wstring ext = string2wstring(name.pathExtension.length ? [@"." stringByAppendingString: name.pathExtension].UTF8String : "");

	// The parser moves the target and search flags of the view; keep the user's.
	sptr_t flags = sci(e, SCI_GETSEARCHFLAGS);
	sptr_t ts = sci(e, SCI_GETTARGETSTART), te = sci(e, SCI_GETTARGETEND);
	std::vector<foundInfo> found;
	bool parsedOK = _parsers.parse(found, AssociationInfo(-1, langID, ext.c_str(), nullptr));
	sci(e, SCI_SETSEARCHFLAGS, flags);
	sci(e, SCI_SETTARGETRANGE, ts, te);

	_full = nil;
	if (parsedOK)
	{
		NppFuncItem* root = [[NppFuncItem alloc] init];
		root.name = name;
		root.kind = kRoot;
		root.pos = -1;
		root.children = [NSMutableArray array];
		for (const auto& fi : found)
		{
			// addEntry: functions inside a class go under its node.
			NSMutableArray* parent = root.children;
			if (!fi._data2.empty())
			{
				NSString* node = @(fi._data2.c_str()) ?: @"";
				NppFuncItem* n = nil;
				for (NppFuncItem* c in root.children)
					if (c.kind == kNode && [c.name isEqualToString: node])
						n = c;
				if (!n)
				{
					n = [[NppFuncItem alloc] init];
					n.name = node;
					n.kind = kNode;
					n.pos = -1;
					n.children = [NSMutableArray array];
					[root.children addObject: n];
				}
				parent = n.children;
			}
			NppFuncItem* leaf = [[NppFuncItem alloc] init];
			leaf.name = @(fi._data.c_str()) ?: @"";
			leaf.kind = kLeaf;
			leaf.pos = fi._pos;
			[parent addObject: leaf];
		}
		_full = root;
	}

	NSDictionary* st = _states[b.path ?: b.displayName];
	_search.stringValue = st ? st[@"search"] : @"";
	BOOL sort = st ? [st[@"sort"] boolValue] : NppSettings::instance()._shouldSortFunctionList;
	_sortButton.state = sort ? NSControlStateValueOn : NSControlStateValueOff;
	[self rebuildShown];
	[self markEntry];
}

// searchFuncAndSwitchView + sortOrUnsort: filtered leaves (case-insensitive),
// classes before functions when unsorted, alphabetical when sorted.
- (void)rebuildShown
{
	NSString* text = _search.stringValue;
	BOOL sort = _sortButton.state == NSControlStateValueOn;
	NppFuncItem* (^copyTree)(NppFuncItem*) = nil;
	__block __weak NppFuncItem* (^weakCopy)(NppFuncItem*);
	copyTree = ^NppFuncItem*(NppFuncItem* it) {
		NppFuncItem* c = [[NppFuncItem alloc] init];
		c.name = it.name;
		c.kind = it.kind;
		c.pos = it.pos;
		if (it.children)
		{
			c.children = [NSMutableArray array];
			for (NppFuncItem* ch in it.children)
			{
				if (ch.kind == kLeaf && text.length && [ch.name rangeOfString: text options: NSCaseInsensitiveSearch].location == NSNotFound)
					continue;
				NppFuncItem* cc = weakCopy(ch);
				if (cc.kind == kNode && text.length && !cc.children.count)
					continue;
				[c.children addObject: cc];
			}
			if (sort)
				[c.children sortUsingComparator: ^NSComparisonResult(NppFuncItem* a, NppFuncItem* b) {
					return [a.name localizedCaseInsensitiveCompare: b.name];
				}];
			else
				[c.children sortWithOptions: NSSortStable usingComparator: ^NSComparisonResult(NppFuncItem* a, NppFuncItem* b) {
					return a.kind == b.kind ? NSOrderedSame : (a.kind == kNode ? NSOrderedAscending : NSOrderedDescending);
				}];
		}
		return c;
	};
	weakCopy = copyTree;
	_shown = _full ? copyTree(_full) : nil;
	[_tree reloadData];
	if (_shown)
	{
		[_tree expandItem: _shown];
		if (text.length)
			[_tree expandItem: _shown expandChildren: YES];
	}
}

- (void)searchChanged:(id)sender
{
	[self rebuildShown];
}

- (void)toggleSort:(id)sender
{
	[self rebuildShown];
}

- (void)reloadClicked:(id)sender
{
	[self reload];
}

- (void)showPreferences:(NSButton*)sender
{
	NSMenu* m = [[NSMenu alloc] init];
	NSMenuItem* mi = [m addItemWithTitle: @"Sort functions (A to Z) by default" action: @selector(toggleDefaultSort:) keyEquivalent: @""];
	mi.target = self;
	mi.state = NppSettings::instance()._shouldSortFunctionList ? NSControlStateValueOn : NSControlStateValueOff;
	[m popUpMenuPositioningItem: nil atLocation: NSMakePoint(0, sender.bounds.size.height) inView: sender];
}

- (void)toggleDefaultSort:(id)sender
{
	NppSettings& s = NppSettings::instance();
	s._shouldSortFunctionList = !s._shouldSortFunctionList;
}

#pragma mark Navigation

// FunctionListPanel::openSelection
- (void)openSelection:(id)sender
{
	NppFuncItem* it = [_tree itemAtRow: _tree.clickedRow >= 0 ? _tree.clickedRow : _tree.selectedRow];
	if (!it || it.kind != kLeaf || it.pos < 0)
		return;
	ScintillaView* e = _window.editor;
	sptr_t line = sci(e, SCI_LINEFROMPOSITION, it.pos);
	sci(e, SCI_ENSUREVISIBLE, line);
	// ScintillaEditView::scrollPosToCenter
	sci(e, SCI_GOTOPOS, it.pos);
	sptr_t firstVisible = sci(e, SCI_GETFIRSTVISIBLELINE);
	sptr_t linesOnScreen = sci(e, SCI_LINESONSCREEN);
	sptr_t visibleLine = sci(e, SCI_VISIBLEFROMDOCLINE, line);
	sptr_t middle = firstVisible + linesOnScreen / 2;
	sci(e, SCI_LINESCROLL, 0, visibleLine - middle);
	if (_tree.clickedRow >= 0 && NSApp.currentEvent.clickCount > 1)
		[_window.window makeFirstResponder: e.content];
}

// FunctionListPanel::markEntry: select the function the caret is in.
- (void)markEntry
{
	if (!_visible || !_shown)
		return;
	ScintillaView* e = _window.editor;
	long lineNr = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS));
	if (_findLine != -1 && _findEndLine != -1 && lineNr >= _findLine && lineNr < _findEndLine)
		return;
	_findLine = -1;
	_findEndLine = -1;
	__block NppFuncItem* found = nil;
	__block void (^walk)(NppFuncItem*);
	__block __weak void (^weakWalk)(NppFuncItem*);
	walk = ^(NppFuncItem* it) {
		for (NppFuncItem* c in it.children)
		{
			if (c.children)
			{
				weakWalk(c);
				continue;
			}
			if (c.pos < 0)
				continue;
			long l = sci(e, SCI_LINEFROMPOSITION, c.pos);
			if (lineNr >= l)
			{
				if (l > _findLine || _findLine == -1)
				{
					_findLine = l;
					found = c;
				}
			}
			else if (l < _findEndLine || _findEndLine == -1)
				_findEndLine = l;
		}
	};
	weakWalk = walk;
	walk(_shown);
	NppFuncItem* target = found ?: _shown;
	for (NppFuncItem* c in _shown.children)
		if (found && c.children && [c.children containsObject: found])
			[_tree expandItem: c];
	NSInteger row = [_tree rowForItem: target];
	if (row >= 0)
	{
		[_tree selectRowIndexes: [NSIndexSet indexSetWithIndex: row] byExtendingSelection: NO];
		[_tree scrollRowToVisible: row];
	}
}

#pragma mark Outline data

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(NppFuncItem*)item
{
	if (!item)
		return _shown ? 1 : 0;
	return item.children.count;
}

- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(NppFuncItem*)item
{
	return item ? item.children[i] : _shown;
}

- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(NppFuncItem*)item
{
	return item.children.count > 0;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(NppFuncItem*)item
{
	NSTableCellView* v = [ov makeViewWithIdentifier: @"func" owner: nil];
	if (!v)
	{
		v = [[NSTableCellView alloc] init];
		v.identifier = @"func";
		NSImageView* iv = [[NSImageView alloc] init];
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
			[iv.leadingAnchor constraintEqualToAnchor: v.leadingAnchor],
			[iv.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
			[iv.widthAnchor constraintEqualToConstant: 14],
			[iv.heightAnchor constraintEqualToConstant: 14],
			[tf.leadingAnchor constraintEqualToAnchor: iv.trailingAnchor constant: 4],
			[tf.trailingAnchor constraintEqualToAnchor: v.trailingAnchor],
			[tf.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
		]];
	}
	v.textField.stringValue = item.name;
	NSString* symbol = item.kind == kRoot ? @"doc.text" : item.kind == kNode ? @"cube" : @"f.cursive";
	v.imageView.image = [NSImage imageWithSystemSymbolName: symbol accessibilityDescription: nil];
	return v;
}

@end
