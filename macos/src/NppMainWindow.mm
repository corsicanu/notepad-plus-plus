#import "NppMainWindow.h"
#import "NppBuffer.h"
#import "NppTabBar.h"
#import "ScintillaView.h"

#include "Scintilla.h"
#include "LangManager.h"

#include <cmath>
#include <cstring>
#include <string>

namespace
{
	// Margins and markers, as set up in ScintillaEditView::init().
	enum { MARGIN_LINENUMBER = 0, MARGIN_SYMBOL = 1, MARGIN_FOLD = 2 };
	const int MARK_BOOKMARK = 20;

	const CGFloat kStatusHeight = 22;

	NSString* const kRecentFilesKey = @"RecentFiles";
	const NSUInteger kMaxRecentFiles = 10;

	NSInteger langIndex(const NppLang* lang)
	{
		return lang - LangManager::instance().languages().data();
	}
}

@interface NppMainWindow () <NppTabBarDelegate, ScintillaNotificationProtocol, NSWindowDelegate>
@end

@implementation NppMainWindow
{
	ScintillaView* _editor;
	NppTabBar* _tabBar;
	NSStackView* _statusBar;
	NSTextField* _statusLang;
	NSTextField* _statusLength;
	NSTextField* _statusPos;
	NSTextField* _statusEOL;
	NSTextField* _statusEncoding;
	NSTextField* _statusMode;

	NSMutableArray<NppBuffer*>* _buffers;
	NSInteger _current;
	BOOL _wordWrap;
}

+ (NSArray<NSString*>*)recentFiles
{
	return [NSUserDefaults.standardUserDefaults stringArrayForKey: kRecentFilesKey] ?: @[];
}

+ (void)clearRecentFiles
{
	[NSUserDefaults.standardUserDefaults removeObjectForKey: kRecentFilesKey];
}

+ (void)addRecentFile:(NSString*)path
{
	NSMutableArray* list = [[self recentFiles] mutableCopy];
	[list removeObject: path];
	[list insertObject: path atIndex: 0];
	while (list.count > kMaxRecentFiles)
		[list removeLastObject];
	[NSUserDefaults.standardUserDefaults setObject: list forKey: kRecentFilesKey];
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 1100, 760)
	                                               styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                                 backing: NSBackingStoreBuffered
	                                                   defer: NO];
	window.minSize = NSMakeSize(400, 250);
	window.frameAutosaveName = @"NotepadPlusPlusMainWindow";
	if (!window.frameAutosaveName.length || ![window setFrameUsingName: @"NotepadPlusPlusMainWindow"])
		[window center];

	if ((self = [super initWithWindow: window]))
	{
		_buffers = [NSMutableArray array];
		_current = -1;
		window.delegate = self;
		[self buildUI];
		[self newDocument: nil];
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

	_tabBar = [[NppTabBar alloc] initWithFrame: NSZeroRect];
	_tabBar.delegate = self;
	_tabBar.translatesAutoresizingMaskIntoConstraints = NO;

	_editor = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 400, 400)];
	_editor.delegate = self;
	_editor.translatesAutoresizingMaskIntoConstraints = NO;

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

	[content addSubview: _tabBar];
	[content addSubview: _editor];
	[content addSubview: _statusBar];

	[NSLayoutConstraint activateConstraints: @[
		[_tabBar.topAnchor constraintEqualToAnchor: content.topAnchor],
		[_tabBar.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_tabBar.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_tabBar.heightAnchor constraintEqualToConstant: 26],
		[_editor.topAnchor constraintEqualToAnchor: _tabBar.bottomAnchor],
		[_editor.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_editor.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_editor.bottomAnchor constraintEqualToAnchor: _statusBar.topAnchor],
		[_statusBar.leadingAnchor constraintEqualToAnchor: content.leadingAnchor],
		[_statusBar.trailingAnchor constraintEqualToAnchor: content.trailingAnchor],
		[_statusBar.bottomAnchor constraintEqualToAnchor: content.bottomAnchor],
		[_statusBar.heightAnchor constraintEqualToConstant: kStatusHeight],
	]];

	[self setupEditor];
}

- (void)setupEditor
{
	ScintillaView* e = _editor;
	[e message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
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

	// Margins: line numbers | bookmarks | folding.
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_LINENUMBER lParam: SC_MARGIN_NUMBER];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_SYMBOL lParam: SC_MARGIN_SYMBOL];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_SYMBOL lParam: 16];
	[e message: SCI_SETMARGINMASKN wParam: MARGIN_SYMBOL lParam: (1 << MARK_BOOKMARK)];
	[e message: SCI_SETMARGINSENSITIVEN wParam: MARGIN_SYMBOL lParam: 1];
	[e message: SCI_SETMARGINTYPEN wParam: MARGIN_FOLD lParam: SC_MARGIN_SYMBOL];
	[e message: SCI_SETMARGINMASKN wParam: MARGIN_FOLD lParam: SC_MASK_FOLDERS];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_FOLD lParam: 14];
	[e message: SCI_SETMARGINSENSITIVEN wParam: MARGIN_FOLD lParam: 1];

	[e message: SCI_MARKERDEFINE wParam: MARK_BOOKMARK lParam: SC_MARK_BOOKMARK];
	[e message: SCI_MARKERSETFORE wParam: MARK_BOOKMARK lParam: 0x000000];
	[e message: SCI_MARKERSETBACK wParam: MARK_BOOKMARK lParam: 0xFF8000]; // BGR: blue-ish like Notepad++'s bookmark

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

	// Brace highlight uses the lexer-independent styles 34/35 from stylers.xml.
	[e message: SCI_SETINDENTATIONGUIDES wParam: SC_IV_LOOKBOTH];
}

#pragma mark - Buffers

- (NppBuffer*)currentBuffer
{
	return (_current >= 0 && _current < (NSInteger)_buffers.count) ? _buffers[_current] : nil;
}

- (NSString*)nextUntitledName
{
	for (int n = 1;; ++n)
	{
		NSString* name = [NSString stringWithFormat: @"new %d", n];
		BOOL used = NO;
		for (NppBuffer* b in _buffers)
			if (!b.path && [b.untitledName isEqualToString: name])
				used = YES;
		if (!used)
			return name;
	}
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

- (void)newDocument:(id)sender
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

		// Like Notepad++, a pristine "new 1" is replaced by the first opened file.
		NppBuffer* cur = [self currentBuffer];
		BOOL reuse = cur && !cur.path && !cur.dirty && [_editor message: SCI_GETLENGTH] == 0;

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
		[self activateBuffer: idx];
	}
}

- (void)closeBufferAtIndex:(NSInteger)index force:(BOOL)force
{
	if (index < 0 || index >= (NSInteger)_buffers.count)
		return;
	NppBuffer* b = _buffers[index];

	if (!force && b.dirty)
	{
		[self activateBuffer: index];
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = [NSString stringWithFormat: @"Save file \"%@\" ?", b.path ?: b.displayName];
		[alert addButtonWithTitle: @"Yes"];
		[alert addButtonWithTitle: @"Cancel"];
		[alert addButtonWithTitle: @"No"];
		NSModalResponse r = [alert runModal];
		if (r == NSAlertSecondButtonReturn)
			return;
		if (r == NSAlertFirstButtonReturn && ![self saveBuffer: b as: NO])
			return;
	}

	// Last tab closing leaves a fresh "new 1", as Notepad++ does.
	if (_buffers.count == 1)
	{
		NppBuffer* fresh = [self addBuffer];
		fresh.untitledName = @"new 1";
	}

	BOOL wasCurrent = index == _current;
	if (wasCurrent)
	{
		NSInteger next = index < (NSInteger)_buffers.count - 1 ? index + 1 : index - 1;
		_current = -1;
		[self activateBuffer: next];
	}
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
		LangManager::instance().apply(_editor, b.lang);
	}
	[NppMainWindow addRecentFile: path];
	[self refreshTabs];
	[self updateStatusBar];
	[self updateTitle];
	return YES;
}

- (BOOL)confirmCloseAll
{
	for (NppBuffer* b in [_buffers copy])
	{
		if (!b.dirty)
			continue;
		[self activateBuffer: [_buffers indexOfObject: b]];
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = [NSString stringWithFormat: @"Save file \"%@\" ?", b.path ?: b.displayName];
		[alert addButtonWithTitle: @"Yes"];
		[alert addButtonWithTitle: @"Cancel"];
		[alert addButtonWithTitle: @"No"];
		NSModalResponse r = [alert runModal];
		if (r == NSAlertSecondButtonReturn)
			return NO;
		if (r == NSAlertFirstButtonReturn && ![self saveBuffer: b as: NO])
			return NO;
	}
	return YES;
}

#pragma mark - Display

- (void)refreshTabs
{
	NSMutableArray* titles = [NSMutableArray array];
	NSMutableArray* states = [NSMutableArray array];
	NSMutableArray* tips = [NSMutableArray array];
	for (NppBuffer* b in _buffers)
	{
		[titles addObject: b.displayName];
		[states addObject: @(b.readOnly ? NppTabReadOnly : b.dirty ? NppTabUnsaved : NppTabSaved)];
		[tips addObject: b.path ?: b.displayName];
	}
	[_tabBar setTabs: titles states: states tooltips: tips];
	_tabBar.selectedIndex = _current;
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
	_statusEncoding.stringValue = [NppBuffer encodingName: b.encoding];
	_statusMode.stringValue = [e message: SCI_GETOVERTYPE] ? @"OVR" : @"INS";
}

#pragma mark - Scintilla notifications

- (void)notification:(SCNotification*)n
{
	NppBuffer* b = [self currentBuffer];
	switch (n->nmhdr.code)
	{
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
			[self highlightBraces];
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

#pragma mark - Tab bar delegate

- (void)tabBar:(NppTabBar*)tabBar didSelectTabAtIndex:(NSInteger)index
{
	[self activateBuffer: index];
}

- (void)tabBar:(NppTabBar*)tabBar didRequestCloseTabAtIndex:(NSInteger)index
{
	[self closeBufferAtIndex: index force: NO];
}

- (void)tabBar:(NppTabBar*)tabBar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
	NppBuffer* cur = [self currentBuffer];
	NppBuffer* moved = _buffers[from];
	[_buffers removeObjectAtIndex: from];
	[_buffers insertObject: moved atIndex: to];
	_current = [_buffers indexOfObject: cur];
	[self refreshTabs];
}

- (void)tabBarDidRequestNewTab:(NppTabBar*)tabBar
{
	[self newDocument: nil];
}

#pragma mark - Window delegate

- (BOOL)windowShouldClose:(NSWindow*)sender
{
	if (![self confirmCloseAll])
		return NO;
	[NSApp terminate: nil];
	return NO;
}

#pragma mark - File menu

- (void)openDocument:(id)sender
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

- (void)reloadFromDisk:(id)sender
{
	NppBuffer* b = [self currentBuffer];
	if (!b.path)
		return;
	if (b.dirty)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = [NSString stringWithFormat: @"Are you sure you want to reload the current file and lose the changes made in Notepad++?"];
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

- (void)saveDocument:(id)sender
{
	[self saveBuffer: [self currentBuffer] as: NO];
}

- (void)saveDocumentAs:(id)sender
{
	[self saveBuffer: [self currentBuffer] as: YES];
}

- (void)saveAllDocuments:(id)sender
{
	NppBuffer* cur = [self currentBuffer];
	for (NppBuffer* b in [_buffers copy])
		if (b.dirty && ![self saveBuffer: b as: NO])
			break;
	[self activateBuffer: [_buffers indexOfObject: cur]];
}

- (void)closeDocument:(id)sender
{
	[self closeBufferAtIndex: _current force: NO];
}

- (void)closeAllDocuments:(id)sender
{
	if (![self confirmCloseAll])
		return;
	while (_buffers.count > 1)
		[self closeBufferAtIndex: _buffers.count - 1 force: YES];
	[self closeBufferAtIndex: 0 force: YES];
}

- (void)closeAllButCurrent:(id)sender
{
	NppBuffer* keep = [self currentBuffer];
	for (NppBuffer* b in [_buffers copy])
		if (b != keep)
		{
			NSUInteger before = _buffers.count;
			[self closeBufferAtIndex: [_buffers indexOfObject: b] force: NO];
			if (_buffers.count == before)
				return; // user cancelled
		}
}

#pragma mark - Edit menu

- (void)duplicateLine:(id)sender  { [_editor message: SCI_SELECTIONDUPLICATE]; }
- (void)deleteLine:(id)sender     { [_editor message: SCI_LINEDELETE]; }
- (void)moveLineUp:(id)sender     { [_editor message: SCI_MOVESELECTEDLINESUP]; }
- (void)moveLineDown:(id)sender   { [_editor message: SCI_MOVESELECTEDLINESDOWN]; }
- (void)toUpperCase:(id)sender    { [_editor message: SCI_UPPERCASE]; }
- (void)toLowerCase:(id)sender    { [_editor message: SCI_LOWERCASE]; }
- (void)joinLines:(id)sender
{
	[_editor message: SCI_TARGETFROMSELECTION];
	[_editor message: SCI_LINESJOIN];
}

- (void)toggleComment:(id)sender
{
	NppBuffer* b = [self currentBuffer];
	if (!b.lang || b.lang->commentLine.empty())
	{
		NSBeep();
		return;
	}
	std::string token = b.lang->commentLine + " ";
	ScintillaView* e = _editor;
	long startLine = [e message: SCI_LINEFROMPOSITION wParam: [e message: SCI_GETSELECTIONSTART]];
	long endLine = [e message: SCI_LINEFROMPOSITION wParam: [e message: SCI_GETSELECTIONEND]];
	if (endLine > startLine && [e message: SCI_GETSELECTIONEND] == [e message: SCI_POSITIONFROMLINE wParam: endLine])
		--endLine;

	// Uncomment when every non-blank line is commented, otherwise comment.
	auto lineIndentPos = [e](long l) { return (long)[e message: SCI_GETLINEINDENTPOSITION wParam: l]; };
	auto lineHasComment = [&](long l) {
		long p = lineIndentPos(l);
		for (size_t i = 0; i < b.lang->commentLine.size(); ++i)
			if ([e message: SCI_GETCHARAT wParam: p + i] != b.lang->commentLine[i])
				return false;
		return true;
	};
	bool allCommented = true;
	for (long l = startLine; l <= endLine; ++l)
		if (lineIndentPos(l) != [e message: SCI_GETLINEENDPOSITION wParam: l] && !lineHasComment(l))
			allCommented = false;

	[e message: SCI_BEGINUNDOACTION];
	for (long l = startLine; l <= endLine; ++l)
	{
		long p = lineIndentPos(l);
		if (p == [e message: SCI_GETLINEENDPOSITION wParam: l])
			continue;
		if (allCommented)
		{
			long len = b.lang->commentLine.size();
			if ([e message: SCI_GETCHARAT wParam: p + len] == ' ')
				++len;
			[e message: SCI_DELETERANGE wParam: p lParam: len];
		}
		else
		{
			[e message: SCI_INSERTTEXT wParam: p lParam: reinterpret_cast<sptr_t>(token.c_str())];
		}
	}
	[e message: SCI_ENDUNDOACTION];
}

#pragma mark - Search menu

- (void)goToLine:(id)sender
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

- (void)toggleBookmarkAtLine:(long)line
{
	if ([_editor message: SCI_MARKERGET wParam: line] & (1 << MARK_BOOKMARK))
		[_editor message: SCI_MARKERDELETE wParam: line lParam: MARK_BOOKMARK];
	else
		[_editor message: SCI_MARKERADD wParam: line lParam: MARK_BOOKMARK];
}

- (void)toggleBookmark:(id)sender
{
	[self toggleBookmarkAtLine: [_editor message: SCI_LINEFROMPOSITION wParam: [_editor message: SCI_GETCURRENTPOS]]];
}

- (void)jumpToBookmark:(BOOL)forward
{
	long line = [_editor message: SCI_LINEFROMPOSITION wParam: [_editor message: SCI_GETCURRENTPOS]];
	long found = forward ? [_editor message: SCI_MARKERNEXT wParam: line + 1 lParam: 1 << MARK_BOOKMARK]
	                     : [_editor message: SCI_MARKERPREVIOUS wParam: line - 1 lParam: 1 << MARK_BOOKMARK];
	if (found < 0) // wrap around
		found = forward ? [_editor message: SCI_MARKERNEXT wParam: 0 lParam: 1 << MARK_BOOKMARK]
		                : [_editor message: SCI_MARKERPREVIOUS wParam: [_editor message: SCI_GETLINECOUNT] lParam: 1 << MARK_BOOKMARK];
	if (found >= 0)
	{
		[_editor message: SCI_ENSUREVISIBLE wParam: found];
		[_editor message: SCI_GOTOLINE wParam: found];
	}
}

- (void)nextBookmark:(id)sender     { [self jumpToBookmark: YES]; }
- (void)previousBookmark:(id)sender { [self jumpToBookmark: NO]; }
- (void)clearBookmarks:(id)sender   { [_editor message: SCI_MARKERDELETEALL wParam: MARK_BOOKMARK]; }

#pragma mark - View menu

- (void)toggleWordWrap:(id)sender
{
	_wordWrap = !_wordWrap;
	[_editor message: SCI_SETWRAPMODE wParam: _wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE];
}

- (void)toggleShowWhitespace:(id)sender
{
	BOOL on = [_editor message: SCI_GETVIEWWS] != SCWS_INVISIBLE;
	[_editor message: SCI_SETVIEWWS wParam: on ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS];
}

- (void)toggleShowEOL:(id)sender
{
	[_editor message: SCI_SETVIEWEOL wParam: ![_editor message: SCI_GETVIEWEOL]];
}

- (void)toggleShowAllChars:(id)sender
{
	BOOL on = [_editor message: SCI_GETVIEWEOL] && [_editor message: SCI_GETVIEWWS] != SCWS_INVISIBLE;
	[_editor message: SCI_SETVIEWEOL wParam: !on];
	[_editor message: SCI_SETVIEWWS wParam: on ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS];
}

- (void)toggleIndentGuides:(id)sender
{
	BOOL on = [_editor message: SCI_GETINDENTATIONGUIDES] != SC_IV_NONE;
	[_editor message: SCI_SETINDENTATIONGUIDES wParam: on ? SC_IV_NONE : SC_IV_LOOKBOTH];
}

- (void)zoomIn:(id)sender      { [_editor message: SCI_ZOOMIN]; }
- (void)zoomOut:(id)sender     { [_editor message: SCI_ZOOMOUT]; }
- (void)zoomRestore:(id)sender { [_editor message: SCI_SETZOOM wParam: 0]; }

- (void)foldAll:(id)sender   { [_editor message: SCI_FOLDALL wParam: SC_FOLDACTION_CONTRACT]; }
- (void)unfoldAll:(id)sender { [_editor message: SCI_FOLDALL wParam: SC_FOLDACTION_EXPAND]; }

- (void)nextTab:(id)sender
{
	if (_buffers.count > 1)
		[self activateBuffer: (_current + 1) % _buffers.count];
}

- (void)previousTab:(id)sender
{
	if (_buffers.count > 1)
		[self activateBuffer: (_current + _buffers.count - 1) % _buffers.count];
}

#pragma mark - Encoding / EOL / Language menus

- (void)setEncodingFromMenu:(NSMenuItem*)sender
{
	NppBuffer* b = [self currentBuffer];
	if (b.encoding == (NppEncoding)sender.tag)
		return;
	b.encoding = (NppEncoding)sender.tag;
	// Changing the encoding is an edit in Notepad++: the file must be saved to apply it.
	if (!b.dirty)
	{
		b.dirty = YES;
		[self refreshTabs];
		[self updateTitle];
	}
	[self updateStatusBar];
}

- (void)setEOLFromMenu:(NSMenuItem*)sender
{
	NppBuffer* b = [self currentBuffer];
	b.eol = (NppEOL)sender.tag;
	[_editor message: SCI_CONVERTEOLS wParam: b.eol];
	[_editor message: SCI_SETEOLMODE wParam: b.eol];
	[self updateStatusBar];
}

- (void)setLanguageFromMenu:(NSMenuItem*)sender
{
	NppBuffer* b = [self currentBuffer];
	const auto& langs = LangManager::instance().languages();
	if (sender.tag < 0 || sender.tag >= (NSInteger)langs.size())
		return;
	b.lang = &langs[sender.tag];
	LangManager::instance().apply(_editor, b.lang);
	[self updateLineNumberMargin];
	[self updateStatusBar];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	NppBuffer* b = [self currentBuffer];
	SEL a = item.action;
	if (a == @selector(setLanguageFromMenu:))
		item.state = (b.lang && langIndex(b.lang) == item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(setEncodingFromMenu:))
		item.state = b.encoding == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(setEOLFromMenu:))
		item.state = b.eol == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(toggleWordWrap:))
		item.state = _wordWrap ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(toggleShowWhitespace:))
		item.state = [_editor message: SCI_GETVIEWWS] != SCWS_INVISIBLE ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(toggleShowEOL:))
		item.state = [_editor message: SCI_GETVIEWEOL] ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(toggleShowAllChars:))
		item.state = ([_editor message: SCI_GETVIEWEOL] && [_editor message: SCI_GETVIEWWS] != SCWS_INVISIBLE) ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(toggleIndentGuides:))
		item.state = [_editor message: SCI_GETINDENTATIONGUIDES] != SC_IV_NONE ? NSControlStateValueOn : NSControlStateValueOff;
	else if (a == @selector(reloadFromDisk:))
		return b.path != nil;
	else if (a == @selector(saveDocument:))
		return b.dirty || !b.path;
	return YES;
}

@end
