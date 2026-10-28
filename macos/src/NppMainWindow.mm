#import "NppMainWindowInternal.h"
#import "NppTabBar.h"
#import "NppIncrementalFind.h"
#import "NppToolbar.h"
#import "NppContextMenus.h"
#import "NppTheme.h"
#import "NppPreferences.h"

#include "LangManager.h"
#include "NppConfig.h"
#include "NppSettings.h"
#include "NppUpstream.h"
#include "EncodingMapper.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>

namespace
{
	const CGFloat kStatusHeight = 22;
	const CGFloat kFinderHeight = 220;

}

@interface NppMainWindow () <NppTabBarDelegate, ScintillaNotificationProtocol, NSWindowDelegate, NSSplitViewDelegate>
- (void)notification:(SCNotification*)n fromPane:(int)pane;
@end

// One of Notepad++'s two views (MAIN_VIEW / SUB_VIEW): tab bar, editor and
// its documents. The main window keeps the active view's state in its own
// ivars and swaps them with this object when the active view changes.
@interface NppPane : NSObject
@property (nonatomic, strong) NSView* container;
@property (nonatomic, strong) NppTabBar* tabBar;
@property (nonatomic, strong) ScintillaView* editor;
@property (nonatomic, strong) NSMutableArray<NppBuffer*>* buffers;
@property (nonatomic) NSInteger current;
@end

@implementation NppPane
@end

// Tells the window which view a Scintilla notification came from.
@interface NppEditorProxy : NSObject <ScintillaNotificationProtocol>
@property (nonatomic, weak) NppMainWindow* window;
@property (nonatomic) int pane;
@end

@implementation NppEditorProxy
- (void)notification:(SCNotification*)n
{
	[_window notification: n fromPane: _pane];
}
@end

@implementation NppMainWindow
{
	ScintillaView* _editor;
	ScintillaView* _invisible;     // off-screen view for searching/replacing other documents
	NppTabBar* _tabBar;
	NSSplitView* _split;           // editor area | search results
	NSView* _editorArea;
	NppFinder* _finder;
	NSStackView* _statusBar;
	NSTextField* _statusLang;
	NSTextField* _statusLength;
	NSTextField* _statusPos;
	NSTextField* _statusEOL;
	NSTextField* _statusEncoding;
	NSTextField* _statusMode;

	NSMutableArray<NppBuffer*>* _buffers;
	NSInteger _current;
	NppFindReplaceDlg* _findReplaceDlg;
	NSMutableArray<NSString*>* _closedFiles;   // for "Restore Recent Closed File"
	NppIncrementalFind* _incFind;
	NppToolbar* _toolbar;
	NSLayoutConstraint* _toolbarHeight;
	NSView* _incBarHolder;
	NSLayoutConstraint* _incBarHeight;

	NppPane* _panes[2];
	NppEditorProxy* _proxies[2];
	int _activePane;
	NSSplitView* _viewSplit;       // main view | sub view
	BOOL _syncV, _syncH;
	long _syncLine[2], _syncX[2];
}

@synthesize editor = _editor;
@synthesize buffers = _buffers;
@synthesize currentIndex = _current;

#pragma mark - Recent files

// The recent file list lives in config.xml (<History>), like lastRecentFileList.
+ (NSArray<NSString*>*)recentFiles
{
	NSMutableArray* a = [NSMutableArray array];
	for (const auto& f : NppConfig::instance().recentFiles)
		[a addObject: [NSString stringWithUTF8String: f.c_str()]];
	return a;
}

+ (void)clearRecentFiles
{
	NppConfig::instance().recentFiles.clear();
}

+ (void)addRecentFile:(NSString*)path
{
	auto& list = NppConfig::instance().recentFiles;
	std::string p = path.UTF8String;
	list.erase(std::remove(list.begin(), list.end(), p), list.end());
	list.insert(list.begin(), p);
	while ((int)list.size() > NppConfig::instance().nbMaxRecentFiles)
		list.pop_back();
}

#pragma mark - Init

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 1100, 760)
	                                               styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                                 backing: NSBackingStoreBuffered
	                                                   defer: NO];
	window.minSize = NSMakeSize(400, 250);
	[window center];
	window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;

	if ((self = [super initWithWindow: window]))
	{
		_closedFiles = [NSMutableArray array];
		window.delegate = self;
		[self buildUI];
		[self restoreWindowFrame];
		[self newDocument];
		[self startSnapshotTimer];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(checkModifiedFiles)
		                                           name: NSApplicationDidBecomeActiveNotification object: nil];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(stylesChanged:)
		                                           name: NppStylesChangedNotification object: nil];
		[NSNotificationCenter.defaultCenter addObserver: self selector: @selector(settingsChanged:)
		                                           name: NppSettingsChangedNotification object: nil];
	}
	return self;
}

#pragma mark - UI

- (NSTextField*)statusField:(CGFloat)minWidth
{
	NSTextField* f = [NSTextField labelWithString: @""];
	f.font = [NSFont systemFontOfSize: 11];
	f.textColor = NSColor.secondaryLabelColor;
	f.lineBreakMode = NSLineBreakByTruncatingTail;
	[f.widthAnchor constraintGreaterThanOrEqualToConstant: minWidth].active = YES;
	return f;
}

- (NSView*)statusSeparator
{
	NSBox* b = [[NSBox alloc] init];
	b.boxType = NSBoxSeparator;
	[b.widthAnchor constraintEqualToConstant: 1].active = YES;
	[b.heightAnchor constraintEqualToConstant: 14].active = YES;
	return b;
}

- (void)buildUI
{
	NSView* content = self.window.contentView;

	for (int i = 0; i < 2; ++i)
	{
		NppPane* p = [[NppPane alloc] init];
		p.tabBar = [[NppTabBar alloc] initWithFrame: NSZeroRect];
		p.tabBar.delegate = self;
		p.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
		p.editor = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 400, 400)];
		_proxies[i] = [[NppEditorProxy alloc] init];
		_proxies[i].window = self;
		_proxies[i].pane = i;
		p.editor.delegate = _proxies[i];
		p.editor.translatesAutoresizingMaskIntoConstraints = NO;
		p.buffers = [NSMutableArray array];
		p.current = -1;
		NSView* c = [[NSView alloc] init];
		[c addSubview: p.tabBar];
		[c addSubview: p.editor];
		[NSLayoutConstraint activateConstraints: @[
			[p.tabBar.topAnchor constraintEqualToAnchor: c.topAnchor],
			[p.tabBar.leadingAnchor constraintEqualToAnchor: c.leadingAnchor],
			[p.tabBar.trailingAnchor constraintEqualToAnchor: c.trailingAnchor],
			[p.tabBar.heightAnchor constraintEqualToConstant: 26],
			[p.editor.topAnchor constraintEqualToAnchor: p.tabBar.bottomAnchor],
			[p.editor.leadingAnchor constraintEqualToAnchor: c.leadingAnchor],
			[p.editor.trailingAnchor constraintEqualToAnchor: c.trailingAnchor],
			[p.editor.bottomAnchor constraintEqualToAnchor: c.bottomAnchor],
		]];
		p.container = c;
		_panes[i] = p;
	}
	_activePane = 0;
	_tabBar = _panes[0].tabBar;
	_editor = _panes[0].editor;
	_buffers = _panes[0].buffers;
	_current = -1;

	_invisible = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 200, 200)];

	// Main view | sub view, side by side (Notepad++'s default vertical splitter).
	_viewSplit = [[NSSplitView alloc] init];
	_viewSplit.vertical = YES;
	_viewSplit.dividerStyle = NSSplitViewDividerStyleThin;
	[_viewSplit addArrangedSubview: _panes[0].container];
	_editorArea = _viewSplit;

	_split = [[NSSplitView alloc] init];
	_split.vertical = NO;
	_split.dividerStyle = NSSplitViewDividerStyleThin;
	_split.delegate = self;
	_split.translatesAutoresizingMaskIntoConstraints = NO;
	[_split addArrangedSubview: _editorArea];

	_statusLang = [self statusField: 160];
	_statusLength = [self statusField: 170];
	_statusPos = [self statusField: 220];
	_statusEOL = [self statusField: 100];
	_statusEncoding = [self statusField: 90];
	_statusMode = [self statusField: 30];
	[_statusLang setContentHuggingPriority: 1 forOrientation: NSLayoutConstraintOrientationHorizontal];
	_statusBar = [NSStackView stackViewWithViews: @[_statusLang, [self statusSeparator], _statusLength, [self statusSeparator],
	                                                _statusPos, [self statusSeparator], _statusEOL, [self statusSeparator],
	                                                _statusEncoding, [self statusSeparator], _statusMode]];
	_statusBar.spacing = 8;
	_statusBar.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 8);
	_statusBar.translatesAutoresizingMaskIntoConstraints = NO;

	// Incremental search bar sits between the editor and the status bar.
	_incBarHolder = [[NSView alloc] init];
	_incBarHolder.translatesAutoresizingMaskIntoConstraints = NO;
	_incBarHolder.hidden = YES;
	_incBarHeight = [_incBarHolder.heightAnchor constraintEqualToConstant: 0];

	// Toolbar from upstream's toolBarIcons[].
	_toolbar = [[NppToolbar alloc] initWithFrame: NSZeroRect];
	_toolbar.translatesAutoresizingMaskIntoConstraints = NO;
	__weak NppMainWindow* weakSelf = self;
	_toolbar.onCommand = ^(int cmd) { [weakSelf runToolbarCommand: cmd]; };
	_toolbar.isEnabled = ^BOOL(int cmd) { return [weakSelf commandState: cmd checked: nil]; };
	_toolbar.isChecked = ^BOOL(int cmd) { BOOL on = NO; [weakSelf commandState: cmd checked: &on]; return on; };
	_toolbarHeight = [_toolbar.heightAnchor constraintEqualToConstant: _toolbar.preferredHeight];

	[content addSubview: _toolbar];
	[content addSubview: _split];
	[content addSubview: _incBarHolder];
	[content addSubview: _statusBar];
	[NSLayoutConstraint activateConstraints: @[
		[_toolbar.topAnchor constraintEqualToAnchor: content.topAnchor],
		[_toolbar.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_toolbar.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		_toolbarHeight,
		[_split.topAnchor constraintEqualToAnchor: _toolbar.bottomAnchor],
		[_split.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_split.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_split.bottomAnchor constraintEqualToAnchor: _incBarHolder.topAnchor],
		[_incBarHolder.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_incBarHolder.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_incBarHolder.bottomAnchor constraintEqualToAnchor: _statusBar.topAnchor],
		_incBarHeight,
		[_statusBar.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_statusBar.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_statusBar.bottomAnchor constraintEqualToAnchor: content.bottomAnchor],
		[_statusBar.heightAnchor constraintEqualToConstant: kStatusHeight],
	]];

	NSMenu* contextMenu = [NppContextMenus editorContextMenu];
	for (NppPane* p : {_panes[0], _panes[1]})
	{
		[self setupEditor: p.editor];
		[self applySettingsToEditor: p.editor];
		p.editor.menu = contextMenu;
		[p.editor message: SCI_USEPOPUP wParam: SC_POPUP_NEVER];
	}
	_toolbar.iconSet = (NppToolbarIconSet)NppSettings::instance()._toolbarIconSet;
	_toolbarHeight.constant = NppSettings::instance()._toolbarShow ? _toolbar.preferredHeight : 0;
	_toolbar.hidden = !NppSettings::instance()._toolbarShow;
}

- (void)setupEditor:(ScintillaView*)e
{
	[e message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
	[e message: SCI_SETIDLESTYLING wParam: SC_IDLESTYLING_ALL];
	[e message: SCI_SETTABWIDTH wParam: 4];
	[e message: SCI_SETUSETABS wParam: 1];
	[e message: SCI_SETMULTIPLESELECTION wParam: 1];
	[e message: SCI_SETADDITIONALSELECTIONTYPING wParam: 1];
	[e message: SCI_SETMULTIPASTE wParam: SC_MULTIPASTE_EACH];
	[e message: SCI_SETVIRTUALSPACEOPTIONS wParam: SCVS_RECTANGULARSELECTION];
	[e message: SCI_SETSCROLLWIDTHTRACKING wParam: 1];
	[e message: SCI_SETSCROLLWIDTH wParam: 1];
	[e message: SCI_SETENDATLASTLINE wParam: 1];
	[e message: SCI_SETCARETLINEVISIBLE wParam: 1];
	[e message: SCI_SETMODEVENTMASK wParam: SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT];

	// Margins: line numbers | bookmarks | change history | folding (ScintillaEditView::init).
	[e message: SCI_SETMARGINS wParam: 4];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_LINENUMBER lParam: SC_MARGIN_NUMBER];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_SYMBOL lParam: SC_MARGIN_SYMBOL];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_SYMBOL lParam: 16];
	[e message: SCI_SETMARGINMASKN wParam: MARGIN_SYMBOL lParam: (1 << MARK_BOOKMARK) | (1 << MARK_HIDELINESBEGIN) | (1 << MARK_HIDELINESEND)];
	[e message: SCI_SETMARGINSENSITIVEN wParam: MARGIN_SYMBOL lParam: 1];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_CHANGEHISTORY lParam: SC_MARGIN_COLOUR];
	[e message: SCI_SETMARGINMASKN wParam: MARGIN_CHANGEHISTORY lParam:
		(1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
		(1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED)];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_CHANGEHISTORY lParam: 9];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_FOLD lParam: SC_MARGIN_SYMBOL];
	[e message: SCI_SETMARGINMASKN wParam: MARGIN_FOLD lParam: SC_MASK_FOLDERS];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_FOLD lParam: 14];
	[e message: SCI_SETMARGINSENSITIVEN wParam: MARGIN_FOLD lParam: 1];
	[e message: SCI_SETCHANGEHISTORY wParam: SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];

	[e message: SCI_MARKERDEFINE wParam: MARK_BOOKMARK lParam: SC_MARK_BOOKMARK];
	[e message: SCI_MARKERSETALPHA wParam: MARK_BOOKMARK lParam: 70];

	// "Box tree" fold style, Notepad++'s default.
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPEN lParam: SC_MARK_BOXMINUS];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDER lParam: SC_MARK_BOXPLUS];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERSUB lParam: SC_MARK_VLINE];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERTAIL lParam: SC_MARK_LCORNER];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEREND lParam: SC_MARK_BOXPLUSCONNECTED];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPENMID lParam: SC_MARK_BOXMINUSCONNECTED];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERMIDTAIL lParam: SC_MARK_TCORNER];
	[e message: SCI_MARKERENABLEHIGHLIGHT wParam: 1];
	[e message: SCI_SETAUTOMATICFOLD wParam: SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
	[e message: SCI_SETFOLDFLAGS wParam: SC_FOLDFLAG_LINEAFTER_CONTRACTED];

	// Find/mark/smart-highlight indicators (ScintillaEditView::init).
	for (int ind : {SCE_UNIVERSAL_FOUND_STYLE_SMART, SCE_UNIVERSAL_FOUND_STYLE, SCE_UNIVERSAL_FOUND_STYLE_INC,
	                SCE_UNIVERSAL_TAGMATCH, SCE_UNIVERSAL_TAGATTR, SCE_UNIVERSAL_FOUND_STYLE_EXT1, SCE_UNIVERSAL_FOUND_STYLE_EXT2,
	                SCE_UNIVERSAL_FOUND_STYLE_EXT3, SCE_UNIVERSAL_FOUND_STYLE_EXT4, SCE_UNIVERSAL_FOUND_STYLE_EXT5})
	{
		[e message: SCI_INDICSETSTYLE wParam: ind lParam: INDIC_ROUNDBOX];
		[e message: SCI_INDICSETALPHA wParam: ind lParam: 100];
		[e message: SCI_INDICSETUNDER wParam: ind lParam: 1];
	}

	[e message: SCI_SETINDENTATIONGUIDES wParam: SC_IV_LOOKBOTH];
}

#pragma mark - Buffers

- (NppBuffer*)currentBuffer
{
	return (_current >= 0 && _current < (NSInteger)_buffers.count) ? _buffers[_current] : nil;
}

- (NppFindReplaceDlg*)findReplaceDlg
{
	if (!_findReplaceDlg)
	{
		_findReplaceDlg = [[NppFindReplaceDlg alloc] init];
		_findReplaceDlg.host = self;
	}
	return _findReplaceDlg;
}

- (NSString*)nextUntitledName
{
	for (int n = 1;; ++n)
	{
		NSString* name = [NSString stringWithFormat: @"new %d", n];
		BOOL used = NO;
		for (NppBuffer* b in [self allBuffers])
			if (!b.path && [b.untitledName isEqualToString: name])
				used = YES;
		if (!used)
			return name;
	}
}

- (void)saveCurrentViewState
{
	[self saveViewState];
}

- (NppBuffer*)openSessionFile:(NSString*)file backup:(NSString*)backup encoding:(int)encoding
{
	if (!backup)
	{
		[self openPaths: @[file]];
		NSInteger i = [self indexOfPath: file];
		return i >= 0 ? _buffers[i] : nil;
	}
	// Unsaved changes from a snapshot: load the backup, keep the original name.
	NppBuffer* cur = [self currentBuffer];
	BOOL reuse = cur && !cur.path && !cur.dirty && [_editor message: SCI_GETLENGTH] == 0 && _buffers.count == 1;
	NppBuffer* b = reuse ? cur : [self addBuffer];
	[self saveViewState];
	_current = [_buffers indexOfObject: b];
	[_editor message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
	if (![b loadFromPath: backup editor: _editor forcedEncoding: encoding error: nil])
		return nil;
	BOOL isPath = [file hasPrefix: @"/"];
	b.path = isPath ? file : nil;
	if (!isPath)
		b.untitledName = file;
	b.lang = LangManager::instance().languageForPath(file.fileSystemRepresentation);
	if (isPath && [NSFileManager.defaultManager fileExistsAtPath: file])
		[b updateTimestamp];
	else
		b.lastModified = nil;
	b.backupPath = backup;
	b.dirty = YES;
	return b;
}

- (void)saveViewState
{
	NppBuffer* b = [self currentBuffer];
	if (!b)
		return;
	b.caretPos = [_editor message: SCI_GETCURRENTPOS];
	b.anchorPos = [_editor message: SCI_GETANCHOR];
	b.firstVisibleLine = [_editor message: SCI_GETFIRSTVISIBLELINE];
}

- (void)applyLanguage:(NppBuffer*)b
{
	LangManager::instance().apply(_editor, b.lang);
	[self updateLineNumberMargin];
	[self updateStatusBar];
}

- (void)activateBuffer:(NSInteger)index
{
	if (index < 0 || index >= (NSInteger)_buffers.count)
		return;
	if (index != _current)
		[self saveViewState];
	_current = index;
	NppBuffer* b = _buffers[index];

	[_editor message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
	[_editor message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
	[_editor message: SCI_SETEOLMODE wParam: b.eol];
	[_editor message: SCI_SETREADONLY wParam: b.readOnly];
	LangManager::instance().apply(_editor, b.lang);
	[_editor message: SCI_SETWRAPMODE wParam: _wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE];

	[_editor message: SCI_SETSEL wParam: b.anchorPos lParam: b.caretPos];
	[_editor message: SCI_SETFIRSTVISIBLELINE wParam: b.firstVisibleLine];

	[self.window makeFirstResponder: _editor.content];
	[self refreshTabs];
	[self updateLineNumberMargin];
	[self updateStatusBar];
	[self updateTitle];
}

- (NppBuffer*)addBuffer
{
	NppBuffer* b = [[NppBuffer alloc] initWithEditor: _editor];
	b.untitledName = [self nextUntitledName];
	[_buffers addObject: b];
	return b;
}

- (void)newDocument
{
	[self addBuffer];
	[self activateBuffer: _buffers.count - 1];
}

- (NSInteger)indexOfPath:(NSString*)path
{
	NSString* std = path.stringByStandardizingPath;
	for (NSUInteger i = 0; i < _buffers.count; ++i)
		if (_buffers[i].path && [_buffers[i].path.stringByStandardizingPath isEqualToString: std])
			return i;
	return -1;
}

- (NSInteger)indexOfUntitled:(NSString*)name
{
	for (NSUInteger i = 0; i < _buffers.count; ++i)
		if (!_buffers[i].path && [_buffers[i].untitledName isEqualToString: name])
			return i;
	return -1;
}

- (void)openPaths:(NSArray<NSString*>*)paths
{
	for (NSString* path in paths)
	{
		NSInteger existing = [self indexOfPath: path];
		if (existing >= 0)
		{
			[self activateBuffer: existing];
			continue;
		}

		BOOL isDir = NO;
		if (![NSFileManager.defaultManager fileExistsAtPath: path isDirectory: &isDir])
		{
			// Notepad++ offers to create a missing file.
			NSAlert* alert = [[NSAlert alloc] init];
			alert.messageText = [NSString stringWithFormat: @"\"%@\" doesn't exist. Create it?", path];
			[alert addButtonWithTitle: @"Yes"];
			[alert addButtonWithTitle: @"No"];
			if ([alert runModal] != NSAlertFirstButtonReturn || ![[NSData data] writeToFile: path atomically: YES])
				continue;
		}
		else if (isDir)
		{
			NSMutableArray* inside = [NSMutableArray array];
			NSDirectoryEnumerator* en = [NSFileManager.defaultManager enumeratorAtPath: path];
			for (NSString* rel in en)
			{
				NSString* full = [path stringByAppendingPathComponent: rel];
				BOOL d = NO;
				if ([NSFileManager.defaultManager fileExistsAtPath: full isDirectory: &d] && !d && ![rel.lastPathComponent hasPrefix: @"."])
					[inside addObject: full];
			}
			[self openPaths: inside];
			continue;
		}

		// Like Notepad++, a pristine "new 1" is replaced by the first opened file.
		NppBuffer* cur = [self currentBuffer];
		BOOL reuse = cur && !cur.path && !cur.dirty && [_editor message: SCI_GETLENGTH] == 0 && _buffers.count == 1;

		NppBuffer* b = reuse ? cur : [self addBuffer];
		NSInteger idx = [_buffers indexOfObject: b];
		if (!reuse)
		{
			[self saveViewState];
			_current = idx;
			[_editor message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
		}
		[_editor message: SCI_SETREADONLY wParam: 0];

		NSError* error = nil;
		if (![b loadFromPath: path editor: _editor error: &error])
		{
			if (!reuse)
				[self closeBufferAtIndex: idx force: YES];
			[[NSAlert alertWithError: error] runModal];
			continue;
		}
		b.caretPos = b.anchorPos = b.firstVisibleLine = 0;
		[NppMainWindow addRecentFile: path];
		[_closedFiles removeObject: path];
		[self activateBuffer: idx];
	}
}

- (void)openDocument
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.allowsMultipleSelection = YES;
	NppBuffer* b = [self currentBuffer];
	if (b.path)
		panel.directoryURL = [NSURL fileURLWithPath: b.path.stringByDeletingLastPathComponent];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSMutableArray* paths = [NSMutableArray array];
	for (NSURL* url in panel.URLs)
		[paths addObject: url.path];
	[self openPaths: paths];
}

- (NSModalResponse)askSave:(NppBuffer*)b
{
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat: @"Save file \"%@\" ?", b.path ?: b.displayName];
	[alert addButtonWithTitle: @"Yes"];
	[alert addButtonWithTitle: @"Cancel"];
	[alert addButtonWithTitle: @"No"];
	return [alert runModal];
}

- (void)closeBufferAtIndex:(NSInteger)index force:(BOOL)force
{
	if (index < 0 || index >= (NSInteger)_buffers.count)
		return;
	NppBuffer* b = _buffers[index];

	if (!force && b.dirty)
	{
		[self activateBuffer: index];
		NSModalResponse r = [self askSave: b];
		if (r == NSAlertSecondButtonReturn)
			return;
		if (r == NSAlertFirstButtonReturn && ![self saveBuffer: b as: NO])
			return;
	}

	if (b.path)
	{
		[_closedFiles removeObject: b.path];
		[_closedFiles addObject: b.path];
	}

	// Last tab of a view: the sub view (or an empty main view next to a
	// visible sub view) disappears; otherwise a fresh "new 1" stays, as upstream.
	if (_buffers.count == 1 && [self paneVisible: 1 - _activePane])
	{
		[_buffers removeObjectAtIndex: 0];
		_current = -1;
		if (![_panes[1 - _activePane].buffers containsObject: b])
			[b releaseDocumentWithEditor: _editor];
		[self hidePane: _activePane];
		return;
	}
	if (_buffers.count == 1)
	{
		NppBuffer* fresh = [self addBuffer];
		fresh.untitledName = @"new 1";
	}

	if (index == _current)
	{
		NSInteger next = index < (NSInteger)_buffers.count - 1 ? index + 1 : index - 1;
		_current = -1;
		[self activateBuffer: next];
	}
	// A cloned document stays alive while the other view still shows it.
	if (![_panes[1 - _activePane].buffers containsObject: b])
		[b releaseDocumentWithEditor: _editor];
	[_buffers removeObjectAtIndex: index];
	if (_current > index)
		--_current;
	[self refreshTabs];
	[self updateTitle];
}

- (BOOL)saveBuffer:(NppBuffer*)b as:(BOOL)saveAs
{
	NSInteger idx = [_buffers indexOfObject: b];
	if (idx != _current)
		[self activateBuffer: idx];

	NSString* path = b.path;
	if (saveAs || !path)
	{
		NSSavePanel* panel = [NSSavePanel savePanel];
		panel.nameFieldStringValue = b.displayName;
		if (b.path)
			panel.directoryURL = [NSURL fileURLWithPath: b.path.stringByDeletingLastPathComponent];
		if ([panel runModal] != NSModalResponseOK)
			return NO;
		path = panel.URL.path;
	}

	NSError* error = nil;
	if (![b saveToPath: path editor: _editor error: &error])
	{
		[[NSAlert alertWithError: error] runModal];
		return NO;
	}
	if (saveAs || !b.lang || b.lang->name == "normal")
	{
		b.lang = LangManager::instance().languageForPath(path.fileSystemRepresentation);
		[self applyLanguage: b];
	}
	[NppMainWindow addRecentFile: path];
	[self refreshTabs];
	[self updateStatusBar];
	[self updateTitle];
	return YES;
}

- (BOOL)saveCopyOf:(NppBuffer*)b
{
	NSSavePanel* panel = [NSSavePanel savePanel];
	panel.nameFieldStringValue = b.displayName;
	if ([panel runModal] != NSModalResponseOK)
		return NO;
	NSError* error = nil;
	BOOL ok = [b writeCopyToPath: panel.URL.path editor: _editor error: &error];
	if (!ok)
		[[NSAlert alertWithError: error] runModal];
	return ok;
}

- (BOOL)confirmCloseBuffers:(NSArray<NppBuffer*>*)list
{
	for (NppBuffer* b in list)
	{
		if (!b.dirty)
			continue;
		[self revealBuffer: b];
		NSModalResponse r = [self askSave: b];
		if (r == NSAlertSecondButtonReturn)
			return NO;
		if (r == NSAlertFirstButtonReturn && ![self saveBuffer: b as: NO])
			return NO;
	}
	return YES;
}

- (BOOL)confirmCloseAll
{
	return [self confirmCloseBuffers: [self allBuffers]];
}

- (void)reloadCurrent
{
	NppBuffer* b = [self currentBuffer];
	if (!b.path)
		return;
	if (b.dirty)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @"Are you sure you want to reload the current file and lose the changes made in Notepad++?";
		[alert addButtonWithTitle: @"Yes"];
		[alert addButtonWithTitle: @"No"];
		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;
	}
	long line = [_editor message: SCI_GETFIRSTVISIBLELINE];
	long pos = [_editor message: SCI_GETCURRENTPOS];
	[_editor message: SCI_SETREADONLY wParam: 0];
	NSError* error = nil;
	if (![b loadFromPath: b.path editor: _editor error: &error])
		[[NSAlert alertWithError: error] runModal];
	b.caretPos = b.anchorPos = std::min(pos, (long)[_editor message: SCI_GETLENGTH]);
	b.firstVisibleLine = line;
	[self activateBuffer: _current];
}

- (void)renameCurrent
{
	NppBuffer* b = [self currentBuffer];
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = b.path ? @"Rename Current File" : @"Rename Current Tab";
	NSTextField* field = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 320, 24)];
	field.stringValue = b.displayName;
	alert.accessoryView = field;
	[alert addButtonWithTitle: @"OK"];
	[alert addButtonWithTitle: @"Cancel"];
	alert.window.initialFirstResponder = field;
	if ([alert runModal] != NSAlertFirstButtonReturn || !field.stringValue.length)
		return;
	if (!b.path)
	{
		b.untitledName = field.stringValue;
	}
	else
	{
		NSString* newPath = [b.path.stringByDeletingLastPathComponent stringByAppendingPathComponent: field.stringValue];
		NSError* error = nil;
		if (![NSFileManager.defaultManager moveItemAtPath: b.path toPath: newPath error: &error])
		{
			[[NSAlert alertWithError: error] runModal];
			return;
		}
		b.path = newPath;
		b.lang = LangManager::instance().languageForPath(newPath.fileSystemRepresentation);
		[self applyLanguage: b];
	}
	[self refreshTabs];
	[self updateTitle];
}

- (void)deleteCurrentFile
{
	NppBuffer* b = [self currentBuffer];
	if (!b.path)
		return;
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat: @"Are you sure you want to move \"%@\" to the Trash?", b.path];
	[alert addButtonWithTitle: @"Yes"];
	[alert addButtonWithTitle: @"No"];
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	NSError* error = nil;
	if (![NSFileManager.defaultManager trashItemAtURL: [NSURL fileURLWithPath: b.path] resultingItemURL: nil error: &error])
	{
		[[NSAlert alertWithError: error] runModal];
		return;
	}
	[self closeBufferAtIndex: _current force: YES];
}

- (void)restoreLastClosedFile
{
	while (_closedFiles.count)
	{
		NSString* p = _closedFiles.lastObject;
		[_closedFiles removeLastObject];
		if ([NSFileManager.defaultManager fileExistsAtPath: p])
		{
			[self openPaths: @[p]];
			return;
		}
	}
}

#pragma mark - Display

- (NSColor*)tabColor:(int)index
{
	if (index < 0 || index > 4)
		return nil;
	BOOL dark = [self.window.effectiveAppearance bestMatchFromAppearancesWithNames: @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
	std::string name = (dark ? "Tab color dark mode " : "Tab color ") + std::to_string(index + 1);
	const NppStyle* st = LangManager::instance().globalStyle(name);
	if (!st || st->bgColor < 0)
		return nil;
	int c = st->bgColor;
	return [NSColor colorWithSRGBRed: ((c >> 16) & 0xFF) / 255.0 green: ((c >> 8) & 0xFF) / 255.0 blue: (c & 0xFF) / 255.0 alpha: 1];
}

- (void)refreshTabs
{
	NSMutableArray* tabs = [NSMutableArray array];
	for (NppBuffer* b in _buffers)
	{
		NppTabInfo* t = [[NppTabInfo alloc] init];
		t.title = b.displayName;
		t.tooltip = b.path ?: b.displayName;
		t.state = (b.readOnly || b.fileReadOnly) ? NppTabReadOnly : b.dirty ? NppTabUnsaved : NppTabSaved;
		t.pinned = b.pinned;
		t.color = [self tabColor: b.tabColor];
		[tabs addObject: t];
	}
	const NppSettings& s = NppSettings::instance();
	_tabBar.showCloseButton = s._tabCloseButton;
	_tabBar.doubleClickCloses = s._tabDoubleClickClose;
	_tabBar.lockDrag = !s._tabDragAndDrop;
	_tabBar.drawTopBar = s._tabDrawTopBar;
	_tabBar.showPinButton = s._tabPinButton;
	[_tabBar setTabs: tabs];
	_tabBar.selectedIndex = _current;
	[self updateToolbar];
}

- (void)updateTitle
{
	NppBuffer* b = [self currentBuffer];
	if (!b)
		return;
	NSString* name = b.path ?: b.displayName;
	self.window.title = [NSString stringWithFormat: @"%@%@ - Notepad++", b.dirty ? @"*" : @"", name];
	self.window.representedURL = b.path ? [NSURL fileURLWithPath: b.path] : nil;
	self.window.documentEdited = b.dirty;
}

- (void)updateLineNumberMargin
{
	long lines = [_editor message: SCI_GETLINECOUNT];
	int digits = std::max(3, (int)std::log10((double)std::max(lines, 1L)) + 1);
	std::string sample(digits + 1, '9');
	sample[0] = '_';
	long w = [_editor message: SCI_TEXTWIDTH wParam: STYLE_LINENUMBER lParam: reinterpret_cast<sptr_t>(sample.c_str())];
	[_editor message: SCI_SETMARGINWIDTHN wParam: MARGIN_LINENUMBER lParam: w + 4];
}

static NSString* withThousands(long n)
{
	static NSNumberFormatter* fmt = [] {
		NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
		f.numberStyle = NSNumberFormatterDecimalStyle;
		return f;
	}();
	return [fmt stringFromNumber: @(n)];
}

- (void)updateStatusBar
{
	NppBuffer* b = [self currentBuffer];
	if (!b)
		return;
	ScintillaView* e = _editor;

	NSString* lang = @"Normal text file";
	if (b.lang && b.lang->name != "normal")
		lang = [NSString stringWithFormat: @"%s file", b.lang->displayName.c_str()];
	_statusLang.stringValue = lang;

	_statusLength.stringValue = [NSString stringWithFormat: @"length : %@    lines : %@",
	                             withThousands([e message: SCI_GETLENGTH]), withThousands([e message: SCI_GETLINECOUNT])];

	long pos = [e message: SCI_GETCURRENTPOS];
	long line = [e message: SCI_LINEFROMPOSITION wParam: pos];
	long col = [e message: SCI_GETCOLUMN wParam: pos];
	long selChars = 0, selLines = 0;
	long nSel = [e message: SCI_GETSELECTIONS];
	for (long i = 0; i < nSel; ++i)
	{
		long s = [e message: SCI_GETSELECTIONNSTART wParam: i];
		long en = [e message: SCI_GETSELECTIONNEND wParam: i];
		if (s != en)
		{
			selChars += [e message: SCI_COUNTCHARACTERS wParam: s lParam: en];
			selLines += [e message: SCI_LINEFROMPOSITION wParam: en] - [e message: SCI_LINEFROMPOSITION wParam: s] + 1;
		}
	}
	_statusPos.stringValue = selChars
		? [NSString stringWithFormat: @"Ln : %@    Col : %@    Sel : %@ | %@", withThousands(line + 1), withThousands(col + 1), withThousands(selChars), withThousands(selLines)]
		: [NSString stringWithFormat: @"Ln : %@    Col : %@    Pos : %@", withThousands(line + 1), withThousands(col + 1), withThousands(pos + 1)];

	static NSString* eolNames[] = {@"Windows (CR LF)", @"Macintosh (CR)", @"Unix (LF)"};
	_statusEOL.stringValue = eolNames[b.eol];
	_statusEncoding.stringValue = [self encodingDisplayName: b];
	_statusMode.stringValue = [e message: SCI_GETOVERTYPE] ? @"OVR" : @"INS";
}

// Port of Notepad_plus::setUniModeText: codepages show their Encoding-menu label.
- (NSString*)encodingDisplayName:(NppBuffer*)b
{
	if (b.encoding == -1)
	{
		switch (b.unicodeMode)
		{
			case uniUTF8: return @"UTF-8-BOM";
			case uni16BE: return @"UTF-16 BE BOM";
			case uni16LE: return @"UTF-16 LE BOM";
			case uni16BE_NoBOM: return @"UTF-16 Big Endian";
			case uni16LE_NoBOM: return @"UTF-16 Little Endian";
			case uniUTF8_NoBOM: return @"UTF-8";
			default: return @"ANSI";
		}
	}
	int idx = EncodingMapper::getInstance().getIndexFromEncoding(b.encoding);
	NSMenuItem* mi = idx < 0 ? nil : [self menuItemWithTag: IDM_FORMAT_ENCODE + idx in: NSApp.mainMenu];
	return mi ? mi.title : [NSString stringWithFormat: @"CP%d", b.encoding];
}

- (NSMenuItem*)menuItemWithTag:(NSInteger)tag in:(NSMenu*)menu
{
	for (NSMenuItem* mi in menu.itemArray)
	{
		if (mi.tag == tag && !mi.submenu)
			return mi;
		if (mi.submenu)
			if (NSMenuItem* found = [self menuItemWithTag: tag in: mi.submenu])
				return found;
	}
	return nil;
}

#pragma mark - Scintilla notifications

- (void)notification:(SCNotification*)n fromPane:(int)pane
{
	if (pane == _activePane)
	{
		[self notification: n];
		if (n->nmhdr.code == SCN_UPDATEUI && (n->updated & SC_UPDATE_V_SCROLL || n->updated & SC_UPDATE_H_SCROLL))
			[self syncScrollFrom: pane];
		return;
	}
	switch (n->nmhdr.code)
	{
		case SCN_FOCUSIN:
			[self switchToPane: pane];
			break;
		case SCN_SAVEPOINTREACHED:
		case SCN_SAVEPOINTLEFT:
		{
			NppPane* p = _panes[pane];
			if (p.current >= 0 && p.current < (NSInteger)p.buffers.count)
				p.buffers[p.current].dirty = n->nmhdr.code == SCN_SAVEPOINTLEFT;
			[self refreshAllTabs];
			break;
		}
	}
}

- (void)notification:(SCNotification*)n
{
	NppBuffer* b = [self currentBuffer];
	switch (n->nmhdr.code)
	{
		case SCN_MACRORECORD:
			[self macroRecordNotification: n];
			break;
		case SCN_SAVEPOINTREACHED:
		case SCN_SAVEPOINTLEFT:
			if (b)
			{
				b.dirty = n->nmhdr.code == SCN_SAVEPOINTLEFT;
				[self refreshTabs];
				[self updateTitle];
			}
			break;
		case SCN_UPDATEUI:
			[self updateStatusBar];
			[self updateToolbar];
			[self highlightBraces];
			if (n->updated & SC_UPDATE_SELECTION)
				[self smartHighlight];
			break;
		case SCN_MODIFIED:
			if (n->linesAdded)
				[self updateLineNumberMargin];
			break;
		case SCN_MARGINCLICK:
			if (n->margin == MARGIN_SYMBOL)
				[self toggleBookmarkAtLine: [_editor message: SCI_LINEFROMPOSITION wParam: n->position]];
			break;
		case SCN_ZOOM:
			[self updateLineNumberMargin];
			break;
	}
}

- (void)highlightBraces
{
	long pos = [_editor message: SCI_GETCURRENTPOS];
	auto isBrace = [](int c) { return c && std::strchr("()[]{}", c); };
	long bracePos = -1;
	if (pos > 0 && isBrace((int)[_editor message: SCI_GETCHARAT wParam: pos - 1]))
		bracePos = pos - 1;
	else if (isBrace((int)[_editor message: SCI_GETCHARAT wParam: pos]))
		bracePos = pos;

	if (bracePos < 0)
	{
		[_editor message: SCI_BRACEHIGHLIGHT wParam: INVALID_POSITION lParam: INVALID_POSITION];
		return;
	}
	long match = [_editor message: SCI_BRACEMATCH wParam: bracePos];
	if (match == INVALID_POSITION)
		[_editor message: SCI_BRACEBADLIGHT wParam: bracePos];
	else
		[_editor message: SCI_BRACEHIGHLIGHT wParam: bracePos lParam: match];
}

// Port of SmartHighlighter::highlightView.
- (void)smartHighlight
{
	ScintillaView* v = _editor;
	[v message: SCI_SETINDICATORCURRENT wParam: SCE_UNIVERSAL_FOUND_STYLE_SMART];
	[v message: SCI_INDICATORCLEARRANGE wParam: 0 lParam: [v message: SCI_GETLENGTH]];

	const NppSettings& s = NppSettings::instance();
	if (!s._enableSmartHilite || [v message: SCI_GETSELECTIONEMPTY])
		return;

	long curPos = [v message: SCI_GETCURRENTPOS];
	long selStart = [v message: SCI_GETSELECTIONSTART];
	long selEnd = [v message: SCI_GETSELECTIONEND];
	bool isWordOnly = s._smartHiliteUseFindSettings ? s._isMatchWord : s._smartHiliteWordOnly;
	bool isCaseSensitive = s._smartHiliteUseFindSettings ? s._isMatchCase : s._smartHiliteCaseSensitive;

	if (isWordOnly)
	{
		long wordStart = [v message: SCI_WORDSTARTPOSITION wParam: curPos lParam: 1];
		long wordEnd = [v message: SCI_WORDENDPOSITION wParam: wordStart lParam: 1];
		if (wordStart == wordEnd || wordStart != selStart || wordEnd != selEnd)
			return;
	}
	else
	{
		long line = [v message: SCI_LINEFROMPOSITION wParam: curPos];
		if (selEnd - selStart > [v message: SCI_LINELENGTH wParam: line])
			return;
	}

	std::string word(selEnd - selStart + 1, '\0');
	Sci_TextRangeFull tr{{selStart, selEnd}, word.data()};
	[v message: SCI_GETTEXTRANGEFULL wParam: 0 lParam: reinterpret_cast<sptr_t>(&tr)];
	word.resize(selEnd - selStart);
	if (word.empty())
		return;

	long origStart = [v message: SCI_GETTARGETSTART];
	long origEnd = [v message: SCI_GETTARGETEND];

	FindOption fo;
	fo._isMatchCase = isCaseSensitive;
	fo._isWholeWord = isWordOnly;
	long firstLine = [v message: SCI_GETFIRSTVISIBLELINE];
	long nbLines = std::min<long>([v message: SCI_LINESONSCREEN], 400) + 1;
	long prevDocLine = -1;
	SearchEngine& engine = self.findReplaceDlg.engine;
	for (long l = firstLine; l < firstLine + nbLines; ++l)
	{
		long docLine = [v message: SCI_DOCLINEFROMVISIBLE wParam: l];
		if (docLine == prevDocLine)
			continue;
		prevDocLine = docLine;
		long start = [v message: SCI_POSITIONFROMLINE wParam: docLine];
		long end = [v message: SCI_POSITIONFROMLINE wParam: docLine + 1];
		if (end == -1)
		{
			engine.processRange(v, ProcessHighLightAll, word, "", start, [v message: SCI_GETLENGTH], fo);
			break;
		}
		engine.processRange(v, ProcessHighLightAll, word, "", start, end, fo);
	}
	[v message: SCI_SETTARGETRANGE wParam: origStart lParam: origEnd];
}

#pragma mark - Bookmarks / Go to

- (void)toggleBookmarkAtLine:(long)line
{
	if ([_editor message: SCI_MARKERGET wParam: line] & (1 << MARK_BOOKMARK))
		[_editor message: SCI_MARKERDELETE wParam: line lParam: MARK_BOOKMARK];
	else
		[_editor message: SCI_MARKERADD wParam: line lParam: MARK_BOOKMARK];
}

- (void)goToLineDialog
{
	NSAlert* alert = [[NSAlert alloc] init];
	long lines = [_editor message: SCI_GETLINECOUNT];
	alert.messageText = @"Go To...";
	alert.informativeText = [NSString stringWithFormat: @"You are here : %ld\nYou want to go to (1 - %ld) :",
	                         [_editor message: SCI_LINEFROMPOSITION wParam: [_editor message: SCI_GETCURRENTPOS]] + 1, lines];
	NSTextField* field = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 120, 24)];
	alert.accessoryView = field;
	[alert addButtonWithTitle: @"Go"];
	[alert addButtonWithTitle: @"Cancel"];
	alert.window.initialFirstResponder = field;
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	long line = field.integerValue;
	if (line < 1)
		return;
	line = std::min(line, lines);
	[_editor message: SCI_ENSUREVISIBLE wParam: line - 1];
	[_editor message: SCI_GOTOLINE wParam: line - 1];
	[_editor message: SCI_SCROLLCARET];
}

- (NSString*)selectedTextOrWord:(BOOL)expandToWord
{
	long s = [_editor message: SCI_GETSELECTIONSTART];
	long e = [_editor message: SCI_GETSELECTIONEND];
	if (s == e && expandToWord)
	{
		long pos = [_editor message: SCI_GETCURRENTPOS];
		s = [_editor message: SCI_WORDSTARTPOSITION wParam: pos lParam: 1];
		e = [_editor message: SCI_WORDENDPOSITION wParam: pos lParam: 1];
	}
	if (s == e)
		return @"";
	std::string buf(e - s + 1, '\0');
	Sci_TextRangeFull tr{{s, e}, buf.data()};
	[_editor message: SCI_GETTEXTRANGEFULL wParam: 0 lParam: reinterpret_cast<sptr_t>(&tr)];
	buf.resize(e - s);
	return [NSString stringWithUTF8String: buf.c_str()] ?: @"";
}

#pragma mark - Views (main / sub)

- (BOOL)paneVisible:(int)i
{
	return _panes[i].container.superview == _viewSplit;
}

// Saves the active view's state into its pane object and loads another one.
- (void)loadPane:(int)i
{
	NppPane* old = _panes[_activePane];
	old.current = _current;
	_activePane = i;
	NppPane* p = _panes[i];
	_tabBar = p.tabBar;
	_editor = p.editor;
	_buffers = p.buffers;
	_current = p.current;
}

- (void)switchToPane:(int)i
{
	if (i == _activePane || ![self paneVisible: i])
		return;
	[self saveViewState];
	[self loadPane: i];
	[self.window makeFirstResponder: _editor.content];
	[self refreshAllTabs];
	[self updateStatusBar];
	[self updateTitle];
}

- (void)focusPaneOfTabBar:(NppTabBar*)tabBar
{
	for (int i = 0; i < 2; ++i)
		if (_panes[i].tabBar == tabBar)
			[self switchToPane: i];
}

// Runs `block` with each visible view loaded as the active one.
- (void)forBothPanes:(void (^)(void))block
{
	int active = _activePane;
	for (int i = 0; i < 2; ++i)
	{
		if (![self paneVisible: i])
			continue;
		[self loadPane: i];
		block();
	}
	[self loadPane: active];
}

- (void)refreshAllTabs
{
	[self forBothPanes: ^{ [self refreshTabs]; }];
	// The inactive view's tab bar draws without the active-tab stripe.
	_panes[1 - _activePane].tabBar.drawTopBar = NO;
	_panes[_activePane].tabBar.drawTopBar = NppSettings::instance()._tabDrawTopBar;
	[_panes[0].tabBar setNeedsDisplay: YES];
	[_panes[1].tabBar setNeedsDisplay: YES];
}

- (void)showPane:(int)i
{
	if ([self paneVisible: i])
		return;
	if (i == 1)
		[_viewSplit addArrangedSubview: _panes[1].container];
	else
		[_viewSplit insertArrangedSubview: _panes[0].container atIndex: 0];
	[_viewSplit layoutSubtreeIfNeeded];
	[_viewSplit setPosition: _viewSplit.bounds.size.width / 2 ofDividerAtIndex: 0];
}

- (void)hidePane:(int)i
{
	[_panes[i].container removeFromSuperview];
	if (_activePane == i)
	{
		_panes[i].current = -1;
		[self loadPane: 1 - i];
		[self activateBuffer: _current];
	}
	[self refreshAllTabs];
}

// Port of Notepad_plus::docGotoAnotherEditView: move (or clone) the current
// document to the other view.
- (void)sendCurrentToOtherView:(BOOL)clone
{
	NppBuffer* b = [self currentBuffer];
	if (!b)
		return;
	int from = _activePane, to = 1 - _activePane;
	[self saveViewState];
	long caret = b.caretPos, anchor = b.anchorPos, first = b.firstVisibleLine;

	if (!clone)
	{
		// Leaving the view: drop the tab without releasing the document.
		if (_buffers.count == 1 && from == 0 && ![self paneVisible: to])
		{
			// Keep the main view alive with a fresh document, like upstream.
			NppBuffer* fresh = [self addBuffer];
			fresh.untitledName = [self nextUntitledName];
		}
		NSInteger idx = [_buffers indexOfObject: b];
		[_buffers removeObjectAtIndex: idx];
		if (_buffers.count == 0)
		{
			_current = -1;
			[_panes[from].container removeFromSuperview];
		}
		else
		{
			_current = -1;
			[self activateBuffer: MIN(idx, (NSInteger)_buffers.count - 1)];
		}
	}

	[self showPane: to];
	[self loadPane: to];
	NSInteger existing = [_buffers indexOfObject: b];
	if (existing == NSNotFound)
	{
		[_buffers addObject: b];
		existing = _buffers.count - 1;
	}
	b.caretPos = caret;
	b.anchorPos = anchor;
	b.firstVisibleLine = first;
	_current = -1;
	[self activateBuffer: existing];
	[self refreshAllTabs];
}

// Synchronized vertical / horizontal scrolling (IDM_VIEW_SYNSCROLLV / H).
- (void)setSyncScroll:(BOOL)vertical on:(BOOL)on
{
	(vertical ? _syncV : _syncH) = on;
	for (int i = 0; i < 2; ++i)
	{
		_syncLine[i] = [_panes[i].editor message: SCI_GETFIRSTVISIBLELINE];
		_syncX[i] = [_panes[i].editor message: SCI_GETXOFFSET];
	}
}

- (BOOL)syncScroll:(BOOL)vertical
{
	return vertical ? _syncV : _syncH;
}

- (void)syncScrollFrom:(int)pane
{
	if ((!_syncV && !_syncH) || ![self paneVisible: 0] || ![self paneVisible: 1])
		return;
	ScintillaView* src = _panes[pane].editor;
	ScintillaView* dst = _panes[1 - pane].editor;
	if (_syncV)
	{
		long line = [src message: SCI_GETFIRSTVISIBLELINE];
		long delta = line - _syncLine[pane];
		if (delta)
			[dst message: SCI_LINESCROLL wParam: 0 lParam: delta];
	}
	if (_syncH)
	{
		long x = [src message: SCI_GETXOFFSET];
		long delta = x - _syncX[pane];
		if (delta)
			[dst message: SCI_SETXOFFSET wParam: [dst message: SCI_GETXOFFSET] + delta];
	}
	for (int i = 0; i < 2; ++i)
	{
		_syncLine[i] = [_panes[i].editor message: SCI_GETFIRSTVISIBLELINE];
		_syncX[i] = [_panes[i].editor message: SCI_GETXOFFSET];
	}
}

// Documents of both views, main view first, clones listed once.
- (NSArray<NppBuffer*>*)allBuffers
{
	NSMutableArray* all = [_panes[0].buffers mutableCopy];
	for (NppBuffer* b in _panes[1].buffers)
		if (![all containsObject: b])
			[all addObject: b];
	return all;
}

// Makes `b` the current document, switching view if needed.
- (BOOL)revealBuffer:(NppBuffer*)b
{
	if (![_buffers containsObject: b])
		for (int i = 0; i < 2; ++i)
			if ([self paneVisible: i] && [_panes[i].buffers containsObject: b])
				[self switchToPane: i];
	NSInteger idx = [_buffers indexOfObject: b];
	if (idx == NSNotFound)
		return NO;
	[self activateBuffer: idx];
	return YES;
}

// File > Close All: empties the sub view, then the main view.
- (void)closeAllForced
{
	if ([self paneVisible: 1])
	{
		[self switchToPane: 1];
		while (_activePane == 1 && _buffers.count)
			[self closeBufferAtIndex: _buffers.count - 1 force: YES];
	}
	[self switchToPane: 0];
	while (_buffers.count > 1)
		[self closeBufferAtIndex: _buffers.count - 1 force: YES];
	[self closeBufferAtIndex: 0 force: YES];
}

- (NSArray<ScintillaView*>*)allEditors
{
	return @[_panes[0].editor, _panes[1].editor];
}

- (BOOL)otherViewVisible
{
	return [self paneVisible: 1 - _activePane];
}

- (NSArray<NppBuffer*>*)subViewBuffers
{
	return [self paneVisible: 1] ? _panes[1].buffers : @[];
}

- (int)activeView
{
	return _activePane;
}

#pragma mark - Styles

// Theme switch / Style Configurator edit: restyle every view.
- (void)stylesChanged:(NSNotification*)n
{
	[self forBothPanes: ^{
		NppBuffer* b = [self currentBuffer];
		if (b)
			[self applyLanguage: b];
	}];
	if (_finder)
		[_finder applyStyles];
	[self refreshTabs];
	[_editor setNeedsDisplay: YES];
}

// Preferences changed: re-apply editor, toolbar, tab bar and status bar settings.
- (void)settingsChanged:(NSNotification*)n
{
	const NppSettings& s = NppSettings::instance();
	[self forBothPanes: ^{
		[self applySettingsToEditor: self->_editor];
		[self updateLineNumberMargin];
	}];
	_toolbar.iconSet = (NppToolbarIconSet)s._toolbarIconSet;
	_toolbar.hidden = !s._toolbarShow;
	_toolbarHeight.constant = s._toolbarShow ? _toolbar.preferredHeight : 0;
	_statusBar.hidden = !s._statusBarShow;
	[self refreshTabs];
	[self updateLineNumberMargin];
}

#pragma mark - Toolbar

- (void)runToolbarCommand:(int)cmd
{
	switch (cmd)
	{
		// Standard edit actions go to the focused editor like the menu items do.
		case IDM_EDIT_CUT: [_editor message: SCI_CUT]; break;
		case IDM_EDIT_COPY: [_editor message: SCI_COPY]; break;
		case IDM_EDIT_PASTE: [_editor message: SCI_PASTE]; break;
		case IDM_EDIT_UNDO: [_editor message: SCI_UNDO]; break;
		case IDM_EDIT_REDO: [_editor message: SCI_REDO]; break;
		default: [self runCommand: cmd]; break;
	}
	[self.window makeFirstResponder: _editor.content];
}

// Enabled/checked state of a command, from the same validation the menus use.
- (BOOL)commandState:(int)cmd checked:(BOOL*)checked
{
	BOOL enabled;
	NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: @"" action: @selector(nppCommand:) keyEquivalent: @""];
	mi.tag = cmd;
	switch (cmd)
	{
		case IDM_EDIT_CUT:
		case IDM_EDIT_COPY:
			enabled = ![_editor message: SCI_GETSELECTIONEMPTY];
			break;
		case IDM_EDIT_PASTE: enabled = [_editor message: SCI_CANPASTE]; break;
		case IDM_EDIT_UNDO: enabled = [_editor message: SCI_CANUNDO]; break;
		case IDM_EDIT_REDO: enabled = [_editor message: SCI_CANREDO]; break;
		case IDM_FILE_SAVEALL:
			enabled = NO;
			for (NppBuffer* b in [self allBuffers])
				enabled |= b.dirty;
			break;
		default:
			enabled = [self validateMenuItem: mi];
			break;
	}
	if (checked)
	{
		[self validateMenuItem: mi];
		*checked = mi.state == NSControlStateValueOn;
	}
	return enabled;
}

- (void)updateToolbar
{
	[_toolbar updateStates];
}

#pragma mark - Incremental search

- (void)showIncrementalFind
{
	if (!_incFind)
	{
		__weak NppMainWindow* weak = self;
		_incFind = [[NppIncrementalFind alloc] initWithEngine: &self.findReplaceDlg.engine editor: ^ScintillaView* { return weak.editor; }];
		_incFind.onClose = ^{ [weak hideIncrementalFind]; };
		NSView* bar = _incFind.view;
		bar.frame = NSMakeRect(0, 0, bar.frame.size.width, bar.frame.size.height);
		[_incBarHolder addSubview: bar];
	}
	_incBarHeight.constant = _incFind.view.frame.size.height + 4;
	_incBarHolder.hidden = NO;
	[_incFind focus];
}

- (void)hideIncrementalFind
{
	_incBarHeight.constant = 0;
	_incBarHolder.hidden = YES;
	[self.window makeFirstResponder: _editor.content];
}

#pragma mark - Search results panel

- (NppFinder*)showFinder
{
	if (!_finder)
	{
		_finder = [[NppFinder alloc] initWithFrame: NSMakeRect(0, 0, 400, kFinderHeight)];
		_finder.delegate = self;
		_finder.purgeBeforeSearch = NppSettings::instance()._finderPurgeBeforeEverySearch;
	}
	if (![self finderVisible])
	{
		[_split addArrangedSubview: _finder];
		[_split layoutSubtreeIfNeeded];
		[_split setPosition: _split.bounds.size.height - kFinderHeight ofDividerAtIndex: 0];
	}
	return _finder;
}

- (void)hideFinder
{
	if ([self finderVisible])
		[_finder removeFromSuperview];
	[self.window makeFirstResponder: _editor.content];
}

- (BOOL)finderVisible
{
	return _finder && _finder.superview == _split;
}

- (BOOL)splitView:(NSSplitView*)splitView canCollapseSubview:(NSView*)subview
{
	return NO;
}

- (CGFloat)splitView:(NSSplitView*)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i
{
	return 120;
}

- (ScintillaView*)finder:(NppFinder*)finder openDocument:(NSString*)path
{
	NSInteger idx = [self indexOfPath: path];
	if (idx < 0)
		idx = [self indexOfUntitled: path];
	if (idx < 0)
	{
		if (![NSFileManager.defaultManager fileExistsAtPath: path])
			return nil;
		[self openPaths: @[path]];
		idx = [self indexOfPath: path];
		if (idx < 0)
			return nil;
	}
	if (idx != _current)
		[self activateBuffer: idx];
	[self.window makeFirstResponder: _editor.content];
	return _editor;
}

- (void)finderDidRequestClose:(NppFinder*)finder
{
	[self hideFinder];
}

#pragma mark - NppFindHost

- (ScintillaView*)currentEditor
{
	return _editor;
}

- (BOOL)currentDocumentIsReadOnly
{
	return [self currentBuffer].readOnly;
}

- (NSString*)currentDocumentPath
{
	return [self currentBuffer].path;
}

- (NSString*)currentDocumentName
{
	return [self currentBuffer].displayName;
}

- (void)attachInvisible:(NppBuffer*)b
{
	[_invisible message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
	[_invisible message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
}

- (void)forEachOpenDocument:(void (^)(ScintillaView*, NSString*, BOOL, BOOL*))block
{
	for (NppBuffer* b in [self allBuffers])
	{
		[self attachInvisible: b];
		BOOL modified = NO;
		block(_invisible, b.path ?: b.displayName, b.readOnly, &modified);
		if (modified)
			b.dirty = [_invisible message: SCI_GETMODIFY] != 0;
	}
	[_invisible message: SCI_SETDOCPOINTER wParam: 0 lParam: 0];
	[self refreshAllTabs];
	[self updateTitle];
}

- (BOOL)withFile:(NSString*)path run:(void (^)(ScintillaView*, BOOL*))block
{
	NSInteger idx = [self indexOfPath: path];
	BOOL modified = NO;
	if (idx >= 0)
	{
		NppBuffer* b = _buffers[idx];
		[self attachInvisible: b];
		block(_invisible, &modified);
		if (modified)
			b.dirty = [_invisible message: SCI_GETMODIFY] != 0;
		[_invisible message: SCI_SETDOCPOINTER wParam: 0 lParam: 0];
		return YES;
	}

	NppBuffer* tmp = [[NppBuffer alloc] initWithEditor: _invisible];
	[self attachInvisible: tmp];
	BOOL ok = [tmp loadFromPath: path editor: _invisible error: nil];
	if (ok)
	{
		block(_invisible, &modified);
		if (modified)
			ok = [tmp saveToPath: path editor: _invisible error: nil];
	}
	[_invisible message: SCI_SETDOCPOINTER wParam: 0 lParam: 0];
	[tmp releaseDocumentWithEditor: _invisible];
	return ok;
}

- (void)documentsModifiedByReplace
{
	NppBuffer* b = [self currentBuffer];
	if (b)
		b.dirty = [_editor message: SCI_GETMODIFY] != 0;
	[self refreshTabs];
	[self updateTitle];
	[self updateStatusBar];
}

#pragma mark - Tab bar delegate

- (void)tabBar:(NppTabBar*)tabBar didSelectTabAtIndex:(NSInteger)index
{
	[self focusPaneOfTabBar: tabBar];
	[self activateBuffer: index];
}

- (void)tabBar:(NppTabBar*)tabBar didRequestCloseTabAtIndex:(NSInteger)index
{
	[self focusPaneOfTabBar: tabBar];
	[self closeBufferAtIndex: index force: NO];
}

- (void)tabBar:(NppTabBar*)tabBar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
	[self focusPaneOfTabBar: tabBar];
	NppBuffer* cur = [self currentBuffer];
	NppBuffer* moved = _buffers[from];
	[_buffers removeObjectAtIndex: from];
	[_buffers insertObject: moved atIndex: to];
	_current = [_buffers indexOfObject: cur];
	[self refreshTabs];
}

- (void)tabBarDidRequestNewTab:(NppTabBar*)tabBar
{
	[self focusPaneOfTabBar: tabBar];
	[self newDocument];
}

- (NSMenu*)tabBar:(NppTabBar*)tabBar menuForTabAtIndex:(NSInteger)index
{
	[self focusPaneOfTabBar: tabBar];
	static NSMenu* menu = nil;
	if (!menu)
		menu = [NppContextMenus tabContextMenu];
	return menu;
}

- (void)tabBar:(NppTabBar*)tabBar didRequestPinTabAtIndex:(NSInteger)index
{
	[self focusPaneOfTabBar: tabBar];
	[self activateBuffer: index];
	[self togglePinCurrent];
}

// Port of the TCN_TABPINNED handling: pinned tabs gather on the left.
- (void)togglePinCurrent
{
	NppBuffer* b = [self currentBuffer];
	b.pinned = !b.pinned;
	[_buffers removeObject: b];
	NSUInteger pos = 0;
	while (pos < _buffers.count && _buffers[pos].pinned)
		++pos;
	[_buffers insertObject: b atIndex: pos];
	_current = pos;
	[self refreshTabs];
}

- (void)setCurrentTabColor:(int)color
{
	[self currentBuffer].tabColor = color;
	[self refreshTabs];
}

- (void)moveCurrentTabTo:(NSInteger)to
{
	NppBuffer* b = [self currentBuffer];
	[_buffers removeObject: b];
	to = std::max<NSInteger>(0, std::min<NSInteger>(to, _buffers.count));
	[_buffers insertObject: b atIndex: to];
	_current = to;
	[self refreshTabs];
}

#pragma mark - Test hooks

- (void)runFindTestHook:(NSString*)key value:(NSString*)value
{
	if ([key isEqualToString: @"macrosave"])
	{
		[self saveCurrentMacroNamed: value];
		return;
	}
	if ([key isEqualToString: @"run"])
	{
		[self runUserCommand: value.UTF8String];
		return;
	}
	if ([key isEqualToString: @"insert"])
	{
		[_editor message: SCI_REPLACESEL wParam: 0 lParam: reinterpret_cast<sptr_t>(value.UTF8String)];
		return;
	}
	NppFindReplaceDlg* d = self.findReplaceDlg;
	if ([key isEqualToString: @"text"])
		[d setFindText: value];
	else if ([key isEqualToString: @"replace"])
		[d setReplaceText: value];
	else if ([key isEqualToString: @"dir"])
		[d setDirectory: value filters: nil];
	else if ([key isEqualToString: @"filters"])
		[d setDirectory: [d currentOptions]._directory.empty() ? @"" : @([d currentOptions]._directory.c_str()) filters: value];
	else if ([key isEqualToString: @"dlg"])
		[d execDialogCommand: value.intValue];
}

#pragma mark - Window delegate

- (BOOL)windowShouldClose:(NSWindow*)sender
{
	[NSApp terminate: nil];
	return NO;
}

@end
