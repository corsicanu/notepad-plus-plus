// Docking panels: Document Map (DocumentMap + ViewZoneDlg) and Folder as
// Workspace (FileBrowser).

#import "NppWorkspacePanels.h"
#import "NppMainWindowInternal.h"
#import "NppPanels.h"

#include "LangManager.h"
#include "NppConfig.h"
#include "NppUpstream.h"
#include "fileBrowser_rc.h"

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}
}

#pragma mark - Document Map

// ViewZoneDlg: the translucent zone showing the editor's visible part. It
// takes the mouse: click / drag scrolls the editor, the wheel scrolls it too.
@interface NppViewZone : NSView
@property (nonatomic) CGFloat higherY, lowerY;
@property (nonatomic, copy) void (^onMove)(CGFloat y);
@property (nonatomic, copy) void (^onWheel)(NSEvent* e);
@end

@implementation NppViewZone

- (BOOL)isFlipped
{
	return YES;
}

- (void)drawRect:(NSRect)dirty
{
	if (_lowerY <= _higherY)
		return;
	NSRect zone = NSMakeRect(0, _higherY, self.bounds.size.width, _lowerY - _higherY);
	[[NSColor colorWithSRGBRed: 1.0 green: 0.5 blue: 0.0 alpha: 0.2] setFill];
	NSRectFillUsingOperation(zone, NSCompositingOperationSourceOver);
}

- (void)mouseDown:(NSEvent*)e
{
	if (_onMove)
		_onMove([self convertPoint: e.locationInWindow fromView: nil].y);
}

- (void)mouseDragged:(NSEvent*)e
{
	[self mouseDown: e];
}

- (void)scrollWheel:(NSEvent*)e
{
	if (_onWheel)
		_onWheel(e);
}

@end

@implementation NppDocumentMapPanel
{
	__weak NppMainWindow* _window;
	NSView* _root;
	ScintillaView* _map;
	NppViewZone* _zone;
	BOOL _visible;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_root = [[NSView alloc] init];
		_map = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 200, 400)];
		_map.translatesAutoresizingMaskIntoConstraints = NO;
		_zone = [[NppViewZone alloc] init];
		_zone.translatesAutoresizingMaskIntoConstraints = NO;
		[_root addSubview: _map];
		[_root addSubview: _zone];
		for (NSView* v in @[_map, _zone])
			[NSLayoutConstraint activateConstraints: @[
				[v.topAnchor constraintEqualToAnchor: _root.topAnchor],
				[v.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
				[v.trailingAnchor constraintEqualToAnchor: _root.trailingAnchor],
				[v.bottomAnchor constraintEqualToAnchor: _root.bottomAnchor],
			]];

		// DocumentMap WM_INITDIALOG
		sci(_map, SCI_SETCODEPAGE, SC_CP_UTF8);
		sci(_map, SCI_SETZOOM, static_cast<uptr_t>(-10));
		sci(_map, SCI_SETVSCROLLBAR, 0);
		sci(_map, SCI_SETHSCROLLBAR, 0);
		sci(_map, SCI_SETMODEVENTMASK, SC_MODEVENTMASKALL & 0);
		sci(_map, SCI_SETINDENTATIONGUIDES, SC_IV_NONE);
		sci(_map, SCI_SETCARETSTYLE, CARETSTYLE_INVISIBLE);
		for (int m = 0; m < 5; ++m)
			sci(_map, SCI_SETMARGINWIDTHN, m, 0);

		__weak NppDocumentMapPanel* weakSelf = self;
		_zone.onMove = ^(CGFloat y) { [weakSelf moveEditorTo: y]; };
		_zone.onWheel = ^(NSEvent* e) { [weakSelf.editor scrollWheel: e]; };

		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(reloadMap) name: NppDocumentsChangedNotification object: nil];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(reloadMap) name: NSViewFrameDidChangeNotification object: _root];
		_root.postsFrameChangedNotifications = YES;
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver: self];
}

- (NSString*)title { return @"Document Map"; }
- (NSView*)view { return _root; }

- (ScintillaView*)editor
{
	return _window.editor;
}

- (void)panelDidShow
{
	_visible = YES;
	[self reloadMap];
}

- (void)panelDidHide
{
	_visible = NO;
	// Don't keep a closed document alive through the map.
	sci(_map, SCI_SETDOCPOINTER, 0, 0);
}

// DocumentMap::reloadMap + setSyntaxHiliting.
- (void)reloadMap
{
	ScintillaView* e = self.editor;
	if (!_visible || !e)
		return;
	sptr_t doc = sci(e, SCI_GETDOCPOINTER);
	if (sci(_map, SCI_GETDOCPOINTER) != doc)
		sci(_map, SCI_SETDOCPOINTER, 0, doc);
	sci(_map, SCI_SETCODEPAGE, SC_CP_UTF8);
	LangManager::instance().apply(_map, _window.currentBuffer.lang);
	for (int m = 0; m < 5; ++m)
		sci(_map, SCI_SETMARGINWIDTHN, m, 0);
	sci(_map, SCI_SETZOOM, static_cast<uptr_t>(-10));
	sci(_map, SCI_SETWRAPMODE, sci(e, SCI_GETWRAPMODE));
	sci(_map, SCI_SETWRAPINDENTMODE, sci(e, SCI_GETWRAPINDENTMODE));
	// Folding state
	long lines = sci(e, SCI_GETLINECOUNT);
	for (long l = 0; l < lines; ++l)
		if ((sci(e, SCI_GETFOLDLEVEL, l) & SC_FOLDLEVELHEADERFLAG) && sci(e, SCI_GETFOLDEXPANDED, l) != sci(_map, SCI_GETFOLDEXPANDED, l))
			sci(_map, SCI_FOLDLINE, l, sci(e, SCI_GETFOLDEXPANDED, l) ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT);
	[self scrollMap];
}

// DocumentMap::scrollMap: let the map show the editor's visible range, then
// mark it.
- (void)scrollMap
{
	ScintillaView* e = self.editor;
	if (!_visible || !e)
		return;
	// The client area: what the scroll view shows, not the whole document view.
	NSRect rc = e.content.visibleRect;
	sptr_t higherPos = sci(e, SCI_POSITIONFROMPOINT, 0, 0);
	sptr_t lowerPos = sci(e, SCI_POSITIONFROMPOINT, rc.size.width, rc.size.height);

	sci(_map, SCI_GOTOPOS, higherPos);
	sci(_map, SCI_GOTOPOS, lowerPos);

	sptr_t higherY = sci(_map, SCI_POINTYFROMPOSITION, 0, higherPos);
	sptr_t lowerY;
	sptr_t lineHeightMap = sci(_map, SCI_TEXTHEIGHT, 0);
	if (sci(e, SCI_GETWRAPMODE) == SC_WRAP_NONE)
	{
		sptr_t lineHeightEdit = sci(e, SCI_TEXTHEIGHT, 0);
		lowerY = higherY + lineHeightMap * static_cast<sptr_t>(rc.size.height) / std::max<sptr_t>(1, lineHeightEdit);
	}
	else
		lowerY = sci(_map, SCI_POINTYFROMPOSITION, 0, lowerPos) + lineHeightMap;

	_zone.higherY = higherY;
	_zone.lowerY = lowerY;
	_zone.needsDisplay = YES;
}

// ViewZoneDlg click: the clicked map line becomes the middle of the editor.
- (void)moveEditorTo:(CGFloat)y
{
	ScintillaView* e = self.editor;
	if (!e)
		return;
	sptr_t pos = sci(_map, SCI_POSITIONFROMPOINT, 0, static_cast<sptr_t>(y));
	sptr_t line = sci(_map, SCI_LINEFROMPOSITION, pos);
	sptr_t visible = sci(e, SCI_VISIBLEFROMDOCLINE, line);
	sptr_t onScreen = sci(e, SCI_LINESONSCREEN);
	sci(e, SCI_SETFIRSTVISIBLELINE, std::max<sptr_t>(0, visible - onScreen / 2));
	[self scrollMap];
}

@end

#pragma mark - Folder as Workspace

@interface NppFileItem : NSObject
@property (nonatomic, copy) NSString* path;
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isRoot;
@property (nonatomic, strong) NSArray<NppFileItem*>* children;   // nil until listed
@end

@implementation NppFileItem

- (NSArray<NppFileItem*>*)children
{
	if (!_children && _isDir)
		[self reload];
	return _children;
}

// FileBrowser::getDirectoryStructure: folders first, then files, sorted,
// hidden entries skipped.
- (void)reload
{
	NSFileManager* fm = NSFileManager.defaultManager;
	NSArray<NSURL*>* urls = [fm contentsOfDirectoryAtURL: [NSURL fileURLWithPath: _path]
	                          includingPropertiesForKeys: @[NSURLIsDirectoryKey, NSURLIsPackageKey]
	                                             options: NSDirectoryEnumerationSkipsHiddenFiles error: nil];
	NSMutableArray* dirs = [NSMutableArray array];
	NSMutableArray* files = [NSMutableArray array];
	for (NSURL* u in urls)
	{
		NSNumber* isDir = nil;
		NSNumber* isPkg = nil;
		[u getResourceValue: &isDir forKey: NSURLIsDirectoryKey error: nil];
		[u getResourceValue: &isPkg forKey: NSURLIsPackageKey error: nil];
		NppFileItem* it = [[NppFileItem alloc] init];
		it.path = u.path;
		it.isDir = isDir.boolValue && !isPkg.boolValue;
		[(it.isDir ? dirs : files) addObject: it];
	}
	NSComparator byName = ^NSComparisonResult(NppFileItem* a, NppFileItem* b) {
		return [a.path.lastPathComponent localizedStandardCompare: b.path.lastPathComponent];
	};
	[dirs sortUsingComparator: byName];
	[files sortUsingComparator: byName];
	_children = [dirs arrayByAddingObjectsFromArray: files];
}

@end

@implementation NppFolderAsWorkspacePanel
{
	__weak NppMainWindow* _window;
	NSView* _root;
	NSOutlineView* _tree;
	NSMutableArray<NppFileItem*>* _roots;
	FSEventStreamRef _stream;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super init]))
	{
		_window = window;
		_roots = [NSMutableArray array];

		_tree = [[NSOutlineView alloc] init];
		NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier: @"name"];
		[_tree addTableColumn: col];
		_tree.outlineTableColumn = col;
		_tree.headerView = nil;
		_tree.rowHeight = 18;
		_tree.style = NSTableViewStyleSourceList;
		_tree.dataSource = self;
		_tree.delegate = self;
		_tree.target = self;
		_tree.doubleAction = @selector(openSelected:);
		_tree.menu = [[NSMenu alloc] init];
		_tree.menu.delegate = self;
		[_tree registerForDraggedTypes: @[NSPasteboardTypeFileURL]];

		NSScrollView* sv = [[NSScrollView alloc] init];
		sv.documentView = _tree;
		sv.hasVerticalScroller = YES;
		sv.autohidesScrollers = YES;
		sv.translatesAutoresizingMaskIntoConstraints = NO;

		// Toolbar: Expand All, Collapse All, Locate Current File.
		NSButton* (^tool)(NSString*, NSString*, SEL) = ^(NSString* symbol, NSString* tip, SEL action) {
			NSButton* b = [NSButton buttonWithImage: [NSImage imageWithSystemSymbolName: symbol accessibilityDescription: tip] target: self action: action];
			b.bordered = NO;
			b.toolTip = tip;
			return b;
		};
		NSStackView* bar = [NSStackView stackViewWithViews: @[
			tool(@"scope", @"Locate Current File", @selector(locateCurrentFile:)),
			tool(@"chevron.down.2", @"Expand All Folders", @selector(expandAll:)),
			tool(@"chevron.up.2", @"Collapse All Folders", @selector(collapseAll:)),
		]];
		bar.spacing = 6;
		bar.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);
		bar.translatesAutoresizingMaskIntoConstraints = NO;

		_root = [[NSView alloc] init];
		[_root addSubview: bar];
		[_root addSubview: sv];
		[NSLayoutConstraint activateConstraints: @[
			[bar.topAnchor constraintEqualToAnchor: _root.topAnchor],
			[bar.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[bar.heightAnchor constraintEqualToConstant: 22],
			[sv.topAnchor constraintEqualToAnchor: bar.bottomAnchor constant: 2],
			[sv.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[sv.trailingAnchor constraintEqualToAnchor: _root.trailingAnchor],
			[sv.bottomAnchor constraintEqualToAnchor: _root.bottomAnchor],
		]];

		const NppConfig& c = NppConfig::instance();
		for (const auto& r : c.fileBrowserRoots)
			[self addRoot: @(r.c_str()) save: NO];
		if (!c.fileBrowserSelectedItem.empty())
			[self selectPath: @(c.fileBrowserSelectedItem.c_str())];
	}
	return self;
}

- (void)dealloc
{
	[self stopWatching];
}

- (NSString*)title { return @"Folder as Workspace"; }
- (NSView*)view { return _root; }

#pragma mark Roots

- (void)addRoot:(NSString*)path
{
	[self addRoot: path save: YES];
}

// FileBrowser::addRootFolder: skipped when it is already shown, or inside a
// root that is.
- (void)addRoot:(NSString*)path save:(BOOL)save
{
	path = path.stringByStandardizingPath;
	BOOL isDir = NO;
	if (![NSFileManager.defaultManager fileExistsAtPath: path isDirectory: &isDir] || !isDir)
		return;
	for (NppFileItem* r in _roots)
		if ([path isEqualToString: r.path] || [path hasPrefix: [r.path stringByAppendingString: @"/"]])
		{
			[self selectPath: path];
			return;
		}
	// A new root containing existing ones replaces them.
	NSMutableArray* covered = [NSMutableArray array];
	for (NppFileItem* r in _roots)
		if ([r.path hasPrefix: [path stringByAppendingString: @"/"]])
			[covered addObject: r];
	[_roots removeObjectsInArray: covered];

	NppFileItem* it = [[NppFileItem alloc] init];
	it.path = path;
	it.isDir = YES;
	it.isRoot = YES;
	[_roots addObject: it];
	[_tree reloadData];
	[_tree expandItem: it];
	[self startWatching];
	if (save)
		[self saveRoots];
}

- (void)removeRoot:(NppFileItem*)root
{
	[_roots removeObject: root];
	[_tree reloadData];
	[self startWatching];
	[self saveRoots];
}

- (void)saveRoots
{
	NppConfig& c = NppConfig::instance();
	c.fileBrowserRoots.clear();
	for (NppFileItem* r in _roots)
		c.fileBrowserRoots.push_back(r.path.fileSystemRepresentation);
	NppFileItem* sel = [_tree itemAtRow: _tree.selectedRow];
	c.fileBrowserSelectedItem = sel ? sel.path.fileSystemRepresentation : "";
}

#pragma mark Watching (FileBrowser's folder update threads)

static void fsEventsCallback(ConstFSEventStreamRef, void* info, size_t, void*, const FSEventStreamEventFlags*, const FSEventStreamEventId*)
{
	NppFolderAsWorkspacePanel* panel = (__bridge NppFolderAsWorkspacePanel*)info;
	[NSObject cancelPreviousPerformRequestsWithTarget: panel selector: @selector(refreshTree) object: nil];
	[panel performSelector: @selector(refreshTree) withObject: nil afterDelay: 0.2];
}

- (void)startWatching
{
	[self stopWatching];
	if (!_roots.count)
		return;
	NSMutableArray* paths = [NSMutableArray array];
	for (NppFileItem* r in _roots)
		[paths addObject: r.path];
	FSEventStreamContext ctx = {0, (__bridge void*)self, nullptr, nullptr, nullptr};
	_stream = FSEventStreamCreate(nullptr, fsEventsCallback, &ctx, (__bridge CFArrayRef)paths,
	                              kFSEventStreamEventIdSinceNow, 0.3, kFSEventStreamCreateFlagNone);
	FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
	FSEventStreamStart(_stream);
}

- (void)stopWatching
{
	if (!_stream)
		return;
	FSEventStreamStop(_stream);
	FSEventStreamInvalidate(_stream);
	FSEventStreamRelease(_stream);
	_stream = nullptr;
}

// Re-lists the folders while keeping expansion and selection.
- (void)refreshTree
{
	NSMutableSet* expanded = [NSMutableSet set];
	for (NSInteger r = 0; r < _tree.numberOfRows; ++r)
	{
		NppFileItem* it = [_tree itemAtRow: r];
		if ([_tree isItemExpanded: it])
			[expanded addObject: it.path];
	}
	NppFileItem* sel = [_tree itemAtRow: _tree.selectedRow];
	NSString* selPath = sel.path;
	for (NppFileItem* r in _roots)
		r.children = nil;
	[_tree reloadData];
	for (NSInteger r = 0; r < _tree.numberOfRows; ++r)
	{
		NppFileItem* it = [_tree itemAtRow: r];
		if ([expanded containsObject: it.path])
			[_tree expandItem: it];
	}
	if (selPath)
		[self selectPath: selPath];
}

#pragma mark Outline data

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(NppFileItem*)item
{
	return item ? item.children.count : _roots.count;
}

- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(NppFileItem*)item
{
	return item ? item.children[i] : _roots[i];
}

- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(NppFileItem*)item
{
	return item.isDir;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(NppFileItem*)item
{
	NSTableCellView* v = [ov makeViewWithIdentifier: @"file" owner: nil];
	if (!v)
	{
		v = [[NSTableCellView alloc] init];
		v.identifier = @"file";
		NSImageView* iv = [[NSImageView alloc] init];
		NSTextField* tf = [NSTextField labelWithString: @""];
		tf.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
		tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
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
			[iv.widthAnchor constraintEqualToConstant: 16],
			[iv.heightAnchor constraintEqualToConstant: 16],
			[tf.leadingAnchor constraintEqualToAnchor: iv.trailingAnchor constant: 4],
			[tf.trailingAnchor constraintEqualToAnchor: v.trailingAnchor],
			[tf.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
		]];
	}
	v.textField.stringValue = item.path.lastPathComponent;
	v.imageView.image = [NSWorkspace.sharedWorkspace iconForFile: item.path];
	v.toolTip = item.path;
	return v;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)n
{
	[self saveRoots];
}

// Folders dropped on the panel become roots (FileBrowser drop target).
- (NSDragOperation)outlineView:(NSOutlineView*)ov validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index
{
	[ov setDropItem: nil dropChildIndex: NSOutlineViewDropOnItemIndex];
	return NSDragOperationLink;
}

- (BOOL)outlineView:(NSOutlineView*)ov acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index
{
	NSArray<NSURL*>* urls = [info.draggingPasteboard readObjectsForClasses: @[NSURL.class] options: @{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	for (NSURL* u in urls)
		[self addRoot: u.path];
	return urls.count > 0;
}

#pragma mark Actions

- (NppFileItem*)clickedItem
{
	NSInteger row = _tree.clickedRow >= 0 ? _tree.clickedRow : _tree.selectedRow;
	return row >= 0 ? [_tree itemAtRow: row] : nil;
}

- (void)openSelected:(id)sender
{
	NppFileItem* it = [self clickedItem];
	if (!it)
		return;
	if (it.isDir)
	{
		if ([_tree isItemExpanded: it])
			[_tree collapseItem: it];
		else
			[_tree expandItem: it];
		return;
	}
	[_window openPaths: @[it.path]];
}

- (void)expandAll:(id)sender
{
	for (NppFileItem* r in _roots)
		[_tree expandItem: r expandChildren: YES];
}

- (void)collapseAll:(id)sender
{
	for (NppFileItem* r in _roots)
		[_tree collapseItem: r collapseChildren: YES];
}

// Selects (and reveals) the item for a path inside one of the roots.
- (BOOL)selectPath:(NSString*)path
{
	for (NppFileItem* root in _roots)
	{
		if (![path isEqualToString: root.path] && ![path hasPrefix: [root.path stringByAppendingString: @"/"]])
			continue;
		NppFileItem* cur = root;
		NSArray* comps = [[path substringFromIndex: root.path.length] pathComponents];
		for (NSString* c in comps)
		{
			if ([c isEqualToString: @"/"])
				continue;
			[_tree expandItem: cur];
			NppFileItem* next = nil;
			for (NppFileItem* ch in cur.children)
				if ([ch.path.lastPathComponent isEqualToString: c])
					next = ch;
			if (!next)
				break;
			cur = next;
		}
		NSInteger row = [_tree rowForItem: cur];
		if (row >= 0)
		{
			[_tree selectRowIndexes: [NSIndexSet indexSetWithIndex: row] byExtendingSelection: NO];
			[_tree scrollRowToVisible: row];
		}
		return YES;
	}
	return NO;
}

- (void)locateCurrentFile:(id)sender
{
	NSString* p = _window.currentBuffer.path;
	if (p)
		[self selectPath: p];
}

#pragma mark Context menus (FileBrowser _hGlobalMenu / _hRootMenu / _hFolderMenu / _hFileMenu)

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NppFileItem* it = _tree.clickedRow >= 0 ? [_tree itemAtRow: _tree.clickedRow] : nil;
	auto add = [&](NSString* title, int tag) {
		NSMenuItem* mi = [menu addItemWithTitle: title action: @selector(menuCommand:) keyEquivalent: @""];
		mi.target = self;
		mi.tag = tag;
		mi.representedObject = it;
	};
	if (!it)
	{
		add(@"Add", IDM_FILEBROWSER_ADDROOT);
		add(@"Remove All", IDM_FILEBROWSER_REMOVEALLROOTS);
		return;
	}
	if (it.isRoot)
	{
		add(@"Remove", IDM_FILEBROWSER_REMOVEROOTFOLDER);
		[menu addItem: NSMenuItem.separatorItem];
	}
	if (!it.isDir)
	{
		add(@"Open", IDM_FILEBROWSER_OPENINNPP);
		[menu addItem: NSMenuItem.separatorItem];
	}
	add(@"Copy path", IDM_FILEBROWSER_COPYPATH);
	if (!it.isDir)
	{
		add(@"Copy file name", IDM_FILEBROWSER_COPYFILENAME);
		add(@"Run by system", IDM_FILEBROWSER_SHELLEXECUTE);
	}
	else
		add(@"Find in Files...", IDM_FILEBROWSER_FINDINFILES);
	[menu addItem: NSMenuItem.separatorItem];
	add(@"Finder here", IDM_FILEBROWSER_EXPLORERHERE);
	add(@"Terminal here", IDM_FILEBROWSER_CMDHERE);
}

- (void)menuCommand:(NSMenuItem*)mi
{
	NppFileItem* it = mi.representedObject;
	NSString* dir = it.isDir ? it.path : it.path.stringByDeletingLastPathComponent;
	switch (mi.tag)
	{
		case IDM_FILEBROWSER_ADDROOT:
		{
			NSOpenPanel* p = [NSOpenPanel openPanel];
			p.canChooseDirectories = YES;
			p.canChooseFiles = NO;
			p.message = @"Select a folder to add in Folder as Workspace panel";
			if ([p runModal] == NSModalResponseOK)
				[self addRoot: p.URL.path];
			break;
		}
		case IDM_FILEBROWSER_REMOVEALLROOTS:
			[_roots removeAllObjects];
			[_tree reloadData];
			[self startWatching];
			[self saveRoots];
			break;
		case IDM_FILEBROWSER_REMOVEROOTFOLDER:
			[self removeRoot: it];
			break;
		case IDM_FILEBROWSER_OPENINNPP:
			[_window openPaths: @[it.path]];
			break;
		case IDM_FILEBROWSER_COPYPATH:
		case IDM_FILEBROWSER_COPYFILENAME:
			[NSPasteboard.generalPasteboard clearContents];
			[NSPasteboard.generalPasteboard setString: mi.tag == IDM_FILEBROWSER_COPYPATH ? it.path : it.path.lastPathComponent
			                                  forType: NSPasteboardTypeString];
			break;
		case IDM_FILEBROWSER_SHELLEXECUTE:
			[NSWorkspace.sharedWorkspace openURL: [NSURL fileURLWithPath: it.path]];
			break;
		case IDM_FILEBROWSER_FINDINFILES:
			[_window findInFilesInDirectory: it.path];
			break;
		case IDM_FILEBROWSER_EXPLORERHERE:
			[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs: @[[NSURL fileURLWithPath: it.path]]];
			break;
		case IDM_FILEBROWSER_CMDHERE:
		{
			NSURL* terminal = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier: @"com.apple.Terminal"];
			[NSWorkspace.sharedWorkspace openURLs: @[[NSURL fileURLWithPath: dir]] withApplicationAtURL: terminal
			                        configuration: [NSWorkspaceOpenConfiguration configuration] completionHandler: nil];
			break;
		}
	}
}

@end
