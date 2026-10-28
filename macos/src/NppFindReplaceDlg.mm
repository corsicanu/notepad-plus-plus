#import "NppFindReplaceDlg.h"
#import "NppFinder.h"

#include "NppSettings.h"
#include "NppUpstream.h"
#include "FindReplaceDlg_rc.h"

#include <fnmatch.h>
#include <memory>

namespace
{
	const CGFloat W = 660;
	const CGFloat H = 360;

	std::string str(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }
	NSString* ns(const std::string& s) { return [NSString stringWithUTF8String: s.c_str()] ?: @""; }

	// "*.cpp *.h;!*.bak" -> patterns (Notepad++ separates by ';' and spaces).
	std::vector<std::string> splitPatterns(const std::string& filters)
	{
		std::vector<std::string> out;
		std::string cur;
		for (char c : filters)
		{
			if (c == ';' || c == ' ')
			{
				if (!cur.empty())
					out.push_back(cur);
				cur.clear();
			}
			else
				cur += c;
		}
		if (!cur.empty())
			out.push_back(cur);
		if (out.empty())
			out.push_back("*.*");
		return out;
	}

	// PathMatchSpec semantics: "*.*" matches everything, case-insensitive.
	bool pathMatchSpec(const std::string& name, const std::string& pattern)
	{
		if (pattern == "*.*" || pattern == "*")
			return true;
		return fnmatch(pattern.c_str(), name.c_str(), FNM_CASEFOLD) == 0;
	}

	// Port of matchInList / matchInExcludeDirList (MISC/Common/Common.cpp).
	bool matchInList(const std::string& fileName, const std::vector<std::string>& patterns)
	{
		bool isMatched = false;
		for (const auto& p : patterns)
		{
			if (p.size() > 1 && p[0] == '!')
			{
				if (p[1] == '\\' || p[1] == '/' || p[1] == '+')
					continue;
				if (pathMatchSpec(fileName, p.substr(1)))
					return false;
				continue;
			}
			if (pathMatchSpec(fileName, p))
				isMatched = true;
		}
		return isMatched;
	}

	bool allPatternsAreExclusion(const std::vector<std::string>& patterns)
	{
		for (const auto& p : patterns)
			if (p[0] != '!')
				return false;
		return true;
	}

	bool matchInExcludeDirList(const std::string& dirName, const std::vector<std::string>& patterns, size_t level)
	{
		for (const auto& p : patterns)
		{
			if (p.size() > 3 && p[0] == '!' && p[1] == '+' && (p[2] == '\\' || p[2] == '/'))
			{
				if (pathMatchSpec(dirName, p.substr(3)))
					return true;
			}
			else if (p.size() > 2 && p[0] == '!' && (p[1] == '\\' || p[1] == '/'))
			{
				if (level == 1 && pathMatchSpec(dirName, p.substr(2)))
					return true;
			}
		}
		return false;
	}

	void getMatchedFileNames(NSString* dir, size_t level, const std::vector<std::string>& patterns,
	                         NSMutableArray<NSString*>* out, bool recursive, bool hidden)
	{
		++level;
		NSFileManager* fm = NSFileManager.defaultManager;
		NSArray* names = [[fm contentsOfDirectoryAtPath: dir error: nil] sortedArrayUsingSelector: @selector(localizedStandardCompare:)];
		for (NSString* name in names)
		{
			NSString* full = [dir stringByAppendingPathComponent: name];
			NSURL* url = [NSURL fileURLWithPath: full];
			NSNumber* isDir = nil;
			NSNumber* isHidden = nil;
			[url getResourceValue: &isDir forKey: NSURLIsDirectoryKey error: nil];
			[url getResourceValue: &isHidden forKey: NSURLIsHiddenKey error: nil];
			if (isDir.boolValue)
			{
				NSNumber* isPackage = nil;
				[url getResourceValue: &isPackage forKey: NSURLIsPackageKey error: nil];
				if (!hidden && isHidden.boolValue)
					continue;
				if (recursive && !matchInExcludeDirList(str(name), patterns, level))
					getMatchedFileNames(full, level, patterns, out, recursive, hidden);
			}
			else if (matchInList(str(name), patterns))
			{
				[out addObject: full];
			}
		}
	}
}

@interface NppFindReplaceDlg () <NSWindowDelegate, NSComboBoxDelegate>
@end

@implementation NppFindReplaceDlg
{
	SearchEngine _engine;
	NppFindDialogType _type;

	NSSegmentedControl* _tabs;
	NSComboBox* _findWhat;
	NSComboBox* _replaceWith;
	NSComboBox* _filters;
	NSComboBox* _directory;
	NSTextField* _replaceLabel;
	NSTextField* _filtersLabel;
	NSTextField* _directoryLabel;
	NSButton* _browse;

	NSButton* _inSelection;
	NSButton* _backward;
	NSButton* _wholeWord;
	NSButton* _matchCase;
	NSButton* _wrap;
	NSButton* _modeNormal;
	NSButton* _modeExtended;
	NSButton* _modeRegex;
	NSButton* _dotNewline;
	NSBox* _modeBox;

	NSButton* _followDoc;
	NSButton* _subFolders;
	NSButton* _hiddenFolders;
	NSButton* _bookmarkLine;
	NSButton* _purge;

	NSButton* _transparencyCheck;
	NSButton* _transOnLoseFocus;
	NSButton* _transAlways;
	NSSlider* _transSlider;

	NSMutableArray<NSButton*>* _actionButtons;
	NSTextField* _status;

	// Macro playback (execSavedCommand): options of the step being replayed.
	std::unique_ptr<FindOption> _env;
	FindOption* _savedEnv;
}

- (SearchEngine&)engine
{
	return _engine;
}

- (instancetype)init
{
	NSPanel* panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, W, H)
	                                            styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
	                                              backing: NSBackingStoreBuffered
	                                                defer: YES];
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = NO;
	panel.becomesKeyOnlyIfNeeded = NO;
	panel.title = @"Find";
	if ((self = [super initWithWindow: panel]))
	{
		panel.delegate = self;
		__weak NppFindReplaceDlg* weakSelf = self;
		_engine.setStatus = [weakSelf](const std::string& msg, FindStatus st, const std::string& tip) {
			[weakSelf setStatus: msg status: st tooltip: tip];
		};
		[self buildUI];
		[panel center];
	}
	return self;
}

#pragma mark - UI construction

- (NSTextField*)label:(NSString*)t frame:(NSRect)r
{
	NSTextField* l = [NSTextField labelWithString: t];
	l.alignment = NSTextAlignmentRight;
	l.frame = r;
	[self.window.contentView addSubview: l];
	return l;
}

- (NSComboBox*)combo:(NSRect)r
{
	NSComboBox* c = [[NSComboBox alloc] initWithFrame: r];
	c.completes = NO;
	c.numberOfVisibleItems = 10;
	c.font = [NSFont systemFontOfSize: 13];
	[self.window.contentView addSubview: c];
	return c;
}

- (NSButton*)check:(NSString*)t frame:(NSRect)r action:(SEL)a
{
	NSButton* b = [NSButton checkboxWithTitle: t target: self action: a];
	b.frame = r;
	[self.window.contentView addSubview: b];
	return b;
}

- (NSButton*)radio:(NSString*)t frame:(NSRect)r in:(NSView*)v
{
	NSButton* b = [NSButton radioButtonWithTitle: t target: self action: @selector(searchModeChanged:)];
	b.frame = r;
	[v addSubview: b];
	return b;
}

// Coordinates below are top-left based, like the .rc dialog templates.
- (NSRect)r:(CGFloat)x :(CGFloat)y :(CGFloat)w :(CGFloat)h
{
	return NSMakeRect(x, H - y - h, w, h);
}

- (void)buildUI
{
	NSView* c = self.window.contentView;

	_tabs = [NSSegmentedControl segmentedControlWithLabels: @[@"Find", @"Replace", @"Find in Files", @"Mark"]
	                                          trackingMode: NSSegmentSwitchTrackingSelectOne
	                                                target: self action: @selector(tabChanged:)];
	_tabs.frame = [self r: 16 : 10 : 420 : 24];
	[c addSubview: _tabs];

	[self label: @"Find what :" frame: [self r: 10 : 50 : 100 : 18]];
	_findWhat = [self combo: [self r: 116 : 46 : 330 : 26]];
	_findWhat.delegate = self;
	_replaceLabel = [self label: @"Replace with :" frame: [self r: 10 : 82 : 100 : 18]];
	_replaceWith = [self combo: [self r: 116 : 78 : 330 : 26]];
	_filtersLabel = [self label: @"Filters :" frame: [self r: 10 : 114 : 100 : 18]];
	_filters = [self combo: [self r: 116 : 110 : 330 : 26]];
	_directoryLabel = [self label: @"Directory :" frame: [self r: 10 : 146 : 100 : 18]];
	_directory = [self combo: [self r: 116 : 142 : 300 : 26]];
	_browse = [NSButton buttonWithTitle: @"..." target: self action: @selector(browseDirectory:)];
	_browse.frame = [self r: 418 : 142 : 30 : 26];
	[c addSubview: _browse];

	_inSelection = [self check: @"In selection" frame: [self r: 116 : 112 : 160 : 18] action: @selector(optionChanged:)];
	_bookmarkLine = [self check: @"Bookmark line" frame: [self r: 116 : 80 : 160 : 18] action: @selector(optionChanged:)];
	_purge = [self check: @"Purge for each search" frame: [self r: 280 : 80 : 170 : 18] action: @selector(optionChanged:)];

	_followDoc = [self check: @"Follow current doc." frame: [self r: 116 : 174 : 150 : 18] action: @selector(optionChanged:)];
	_subFolders = [self check: @"In all sub-folders" frame: [self r: 270 : 174 : 140 : 18] action: @selector(optionChanged:)];
	_hiddenFolders = [self check: @"In hidden folders" frame: [self r: 116 : 196 : 150 : 18] action: @selector(optionChanged:)];

	_backward = [self check: @"Backward direction" frame: [self r: 16 : 222 : 180 : 18] action: @selector(optionChanged:)];
	_wholeWord = [self check: @"Match whole word only" frame: [self r: 16 : 244 : 180 : 18] action: @selector(optionChanged:)];
	_matchCase = [self check: @"Match case" frame: [self r: 16 : 266 : 180 : 18] action: @selector(optionChanged:)];
	_wrap = [self check: @"Wrap around" frame: [self r: 16 : 288 : 180 : 18] action: @selector(optionChanged:)];

	_modeBox = [[NSBox alloc] initWithFrame: [self r: 200 : 214 : 250 : 108]];
	_modeBox.title = @"Search Mode";
	_modeBox.titleFont = [NSFont systemFontOfSize: 11];
	[c addSubview: _modeBox];
	NSView* mb = _modeBox.contentView;
	CGFloat mh = mb.bounds.size.height;
	auto mr = [mh](CGFloat x, CGFloat y, CGFloat w) { return NSMakeRect(x, mh - y - 18, w, 18); };
	_modeNormal = [self radio: @"Normal" frame: mr(6, 4, 220) in: mb];
	_modeExtended = [self radio: @"Extended (\\n, \\r, \\t, \\0, \\x...)" frame: mr(6, 24, 230) in: mb];
	_modeRegex = [self radio: @"Regular expression" frame: mr(6, 44, 140) in: mb];
	_dotNewline = [NSButton checkboxWithTitle: @". matches newline" target: self action: @selector(optionChanged:)];
	_dotNewline.frame = mr(110, 64, 130);
	_dotNewline.font = [NSFont systemFontOfSize: 11];
	[mb addSubview: _dotNewline];

	NSBox* tb = [[NSBox alloc] initWithFrame: [self r: 460 : 214 : 186 : 108]];
	tb.title = @"";
	tb.titlePosition = NSNoTitle;
	[c addSubview: tb];
	NSView* tv = tb.contentView;
	CGFloat th = tv.bounds.size.height;
	_transparencyCheck = [NSButton checkboxWithTitle: @"Transparency" target: self action: @selector(transparencyChanged:)];
	_transparencyCheck.frame = NSMakeRect(6, th - 22, 160, 18);
	[tv addSubview: _transparencyCheck];
	_transOnLoseFocus = [NSButton radioButtonWithTitle: @"On losing focus" target: self action: @selector(transparencyChanged:)];
	_transOnLoseFocus.frame = NSMakeRect(18, th - 44, 160, 18);
	[tv addSubview: _transOnLoseFocus];
	_transAlways = [NSButton radioButtonWithTitle: @"Always" target: self action: @selector(transparencyChanged:)];
	_transAlways.frame = NSMakeRect(18, th - 64, 160, 18);
	[tv addSubview: _transAlways];
	_transSlider = [NSSlider sliderWithValue: 150 minValue: 20 maxValue: 225 target: self action: @selector(transparencyChanged:)];
	_transSlider.frame = NSMakeRect(18, th - 90, 150, 20);
	[tv addSubview: _transSlider];

	_status = [NSTextField labelWithString: @""];
	_status.frame = [self r: 16 : 334 : W - 32 : 18];
	_status.lineBreakMode = NSLineBreakByTruncatingTail;
	[c addSubview: _status];

	_actionButtons = [NSMutableArray array];
	[self loadSettings];
	[self tabChanged: nil];
}

- (void)loadSettings
{
	NppSettings& s = NppSettings::instance();
	_wholeWord.state = s._isMatchWord;
	_matchCase.state = s._isMatchCase;
	_wrap.state = s._isWrap;
	_backward.state = !s._isDirectionDown;
	_dotNewline.state = s._dotMatchesNewline;
	(s._searchMode == 2 ? _modeRegex : s._searchMode == 1 ? _modeExtended : _modeNormal).state = NSControlStateValueOn;
	_subFolders.state = s._isFifRecuisive;
	_hiddenFolders.state = s._isFifInHiddenFolder;
	_followDoc.state = s._isFolderFollowDoc;
	_bookmarkLine.state = s._isBookmarkLine;
	_purge.state = s._isPurge;
	_transparencyCheck.state = s._transparencyMode != 0;
	(s._transparencyMode == 2 ? _transAlways : _transOnLoseFocus).state = NSControlStateValueOn;
	_transSlider.integerValue = s._transparency;
	[_findWhat addItemsWithObjectValues: [self nsArray: s._findHistoryFinds]];
	[_replaceWith addItemsWithObjectValues: [self nsArray: s._findHistoryReplaces]];
	[_filters addItemsWithObjectValues: [self nsArray: s._findHistoryFilters]];
	[_directory addItemsWithObjectValues: [self nsArray: s._findHistoryPaths]];
	[self searchModeChanged: nil];
}

- (NSArray*)nsArray:(const std::vector<std::string>&)v
{
	NSMutableArray* a = [NSMutableArray array];
	for (const auto& s : v)
		[a addObject: ns(s)];
	return a;
}

- (void)saveSettings
{
	NppSettings& s = NppSettings::instance();
	s._isMatchWord = _wholeWord.state;
	s._isMatchCase = _matchCase.state;
	s._isWrap = _wrap.state;
	s._isDirectionDown = !_backward.state;
	s._dotMatchesNewline = _dotNewline.state;
	s._searchMode = _modeRegex.state ? 2 : _modeExtended.state ? 1 : 0;
	s._isFifRecuisive = _subFolders.state;
	s._isFifInHiddenFolder = _hiddenFolders.state;
	s._isFolderFollowDoc = _followDoc.state;
	s._isBookmarkLine = _bookmarkLine.state;
	s._isPurge = _purge.state;
	s._transparencyMode = !_transparencyCheck.state ? 0 : _transAlways.state ? 2 : 1;
	s._transparency = (int)_transSlider.integerValue;
	auto save = [](NSComboBox* c, std::vector<std::string>& v) {
		v.clear();
		for (NSString* item in c.objectValues)
			v.push_back(str(item));
	};
	save(_findWhat, s._findHistoryFinds);
	save(_replaceWith, s._findHistoryReplaces);
	save(_filters, s._findHistoryFilters);
	save(_directory, s._findHistoryPaths);
}

- (NSButton*)actionButton:(NSString*)title y:(CGFloat)y action:(SEL)a
{
	NSButton* b = [NSButton buttonWithTitle: title target: self action: a];
	b.frame = [self r: 460 : y : 186 : 28];
	b.font = [NSFont systemFontOfSize: 12];
	[self.window.contentView addSubview: b];
	[_actionButtons addObject: b];
	return b;
}

- (void)tabChanged:(id)sender
{
	if (sender)
		_type = (NppFindDialogType)_tabs.selectedSegment;
	_tabs.selectedSegment = _type;
	static NSString* titles[] = {@"Find", @"Replace", @"Find in Files", @"Mark"};
	self.window.title = titles[_type];

	BOOL replace = _type == NppFindDialogReplace;
	BOOL fif = _type == NppFindDialogFindInFiles;
	BOOL mark = _type == NppFindDialogMark;

	_replaceLabel.hidden = _replaceWith.hidden = !(replace || fif);
	_filtersLabel.hidden = _filters.hidden = !fif;
	_directoryLabel.hidden = _directory.hidden = _browse.hidden = !fif;
	_followDoc.hidden = _subFolders.hidden = _hiddenFolders.hidden = !fif;
	_inSelection.hidden = fif;
	_bookmarkLine.hidden = _purge.hidden = !mark;
	_backward.hidden = fif || mark;
	_wrap.hidden = fif;
	// Mark puts its options where Replace has its field.
	_inSelection.frame = [self r: 116 : mark ? 104 : 112 : 160 : 18];

	for (NSButton* b in _actionButtons)
		[b removeFromSuperview];
	[_actionButtons removeAllObjects];

	NSButton* def = nil;
	switch (_type)
	{
		case NppFindDialogFind:
			def = [self actionButton: @"Find Next" y: 44 action: @selector(doFindNext:)];
			[self actionButton: @"Count" y: 76 action: @selector(doCount:)];
			[self actionButton: @"Find All in Current Document" y: 108 action: @selector(doFindAllCurrent:)];
			[self actionButton: @"Find All in All Opened Documents" y: 140 action: @selector(doFindAllOpened:)];
			[self actionButton: @"Close" y: 172 action: @selector(close:)];
			break;
		case NppFindDialogReplace:
			def = [self actionButton: @"Find Next" y: 44 action: @selector(doFindNext:)];
			[self actionButton: @"Replace" y: 76 action: @selector(doReplace:)];
			[self actionButton: @"Replace All" y: 108 action: @selector(doReplaceAll:)];
			[self actionButton: @"Replace All in All Opened Documents" y: 140 action: @selector(doReplaceAllOpened:)];
			[self actionButton: @"Close" y: 172 action: @selector(close:)];
			break;
		case NppFindDialogFindInFiles:
			def = [self actionButton: @"Find All" y: 44 action: @selector(doFindInFiles:)];
			[self actionButton: @"Replace in Files" y: 76 action: @selector(doReplaceInFiles:)];
			[self actionButton: @"Close" y: 108 action: @selector(close:)];
			break;
		case NppFindDialogMark:
			def = [self actionButton: @"Mark All" y: 44 action: @selector(doMarkAll:)];
			[self actionButton: @"Clear all marks" y: 76 action: @selector(doClearMarks:)];
			[self actionButton: @"Copy Marked Text" y: 108 action: @selector(doCopyMarked:)];
			[self actionButton: @"Close" y: 140 action: @selector(close:)];
			break;
	}
	def.keyEquivalent = @"\r";
	if (fif && !_directory.stringValue.length)
		[self fillDirectoryFromCurrentDoc];
	[self setStatus: "" status: FSNoMessage tooltip: ""];
}

#pragma mark - Showing

- (void)showDialog:(NppFindDialogType)type
{
	_type = type;
	[self tabChanged: nil];

	ScintillaView* ed = [_host currentEditor];
	NppSettings& s = NppSettings::instance();
	long selStart = [ed message: SCI_GETSELECTIONSTART];
	long selEnd = [ed message: SCI_GETSELECTIONEND];

	// "In selection" auto-check for big selections (NppGUI::_inSelectionAutocheckThreshold).
	long selLen = selEnd - selStart;
	_inSelection.enabled = selLen > 0;
	if (s._inSelectionAutocheckThreshold != 0)
		_inSelection.state = selLen >= s._inSelectionAutocheckThreshold;

	// Fill "Find what" with the selection, or the word at the caret.
	if (s._fillFindFieldWithSelected)
	{
		NSString* text = nil;
		if (selLen > 0 && selLen < 1024 && [ed message: SCI_LINEFROMPOSITION wParam: selStart] == [ed message: SCI_LINEFROMPOSITION wParam: selEnd])
			text = [self textFrom: ed start: selStart end: selEnd];
		else if (selLen == 0 && s._fillFindFieldSelectCaret)
		{
			long pos = [ed message: SCI_GETCURRENTPOS];
			long ws = [ed message: SCI_WORDSTARTPOSITION wParam: pos lParam: 1];
			long we = [ed message: SCI_WORDENDPOSITION wParam: pos lParam: 1];
			if (we > ws)
				text = [self textFrom: ed start: ws end: we];
		}
		if (text.length)
			_findWhat.stringValue = text;
	}

	if (_type == NppFindDialogFindInFiles && _followDoc.state)
		[self fillDirectoryFromCurrentDoc];

	[self applyTransparency: YES];
	[self showWindow: nil];
	[self.window makeFirstResponder: _findWhat];
	[[_findWhat currentEditor] selectAll: nil];
}

- (NSString*)textFrom:(ScintillaView*)ed start:(long)s end:(long)e
{
	std::string buf(e - s + 1, '\0');
	Sci_TextRangeFull tr{{s, e}, buf.data()};
	[ed message: SCI_GETTEXTRANGEFULL wParam: 0 lParam: reinterpret_cast<sptr_t>(&tr)];
	buf.resize(e - s);
	return ns(buf);
}

- (void)fillDirectoryFromCurrentDoc
{
	NSString* path = [_host currentDocumentPath];
	if (path)
		_directory.stringValue = path.stringByDeletingLastPathComponent;
}

- (void)close:(id)sender
{
	[self saveSettings];
	[self.window orderOut: nil];
	[[_host currentEditor].window makeKeyWindow];
}

- (void)cancelOperation:(id)sender
{
	[self close: sender];
}

- (void)windowWillClose:(NSNotification*)notification
{
	[self saveSettings];
}

#pragma mark - Options

- (FindOption)currentOptions
{
	if (_savedEnv)
		return *_savedEnv;
	FindOption o;
	o._isWholeWord = _wholeWord.state && !_modeRegex.state;
	o._isMatchCase = _matchCase.state;
	o._isWrapAround = _wrap.state;
	o._whichDirection = _backward.state ? DIR_UP : DIR_DOWN;
	o._searchType = _modeRegex.state ? FindRegex : _modeExtended.state ? FindExtended : FindNormal;
	o._dotMatchesNewline = _dotNewline.state;
	o._isInSelection = _inSelection.state && !_inSelection.hidden && _inSelection.enabled;
	o._doPurge = _purge.state;
	o._doMarkLine = _bookmarkLine.state;
	o._str2Search = str(_findWhat.stringValue);
	o._str4Replace = str(_replaceWith.stringValue);
	o._filters = str(_filters.stringValue);
	o._directory = str(_directory.stringValue);
	o._isRecursive = _subFolders.state;
	o._isInHiddenDir = _hiddenFolders.state;
	return o;
}

- (NSString*)findText
{
	return _findWhat.stringValue;
}

- (void)setFindText:(NSString*)text
{
	_findWhat.stringValue = text ?: @"";
}

- (void)optionChanged:(id)sender
{
	if (sender == _followDoc && _followDoc.state)
		[self fillDirectoryFromCurrentDoc];
	[self saveSettings];
}

- (void)searchModeChanged:(id)sender
{
	BOOL regex = _modeRegex.state == NSControlStateValueOn;
	_dotNewline.enabled = regex;
	// Regex doesn't allow whole word; regex upward search is disabled.
	if (regex)
	{
		_wholeWord.state = NSControlStateValueOff;
		_backward.state = NSControlStateValueOff;
	}
	_wholeWord.enabled = !regex;
	_backward.enabled = !regex;
	if (sender)
		[self saveSettings];
}

- (void)transparencyChanged:(id)sender
{
	_transOnLoseFocus.enabled = _transAlways.enabled = _transSlider.enabled = _transparencyCheck.state;
	[self applyTransparency: self.window.isKeyWindow];
	[self saveSettings];
}

- (void)applyTransparency:(BOOL)focused
{
	CGFloat alpha = 1;
	if (_transparencyCheck.state && (_transAlways.state || !focused))
		alpha = _transSlider.doubleValue / 255.0;
	self.window.alphaValue = alpha;
}

- (void)windowDidBecomeKey:(NSNotification*)n { [self applyTransparency: YES]; }
- (void)windowDidResignKey:(NSNotification*)n { [self applyTransparency: NO]; }

- (void)browseDirectory:(id)sender
{
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = NO;
	p.canChooseDirectories = YES;
	if (_directory.stringValue.length)
		p.directoryURL = [NSURL fileURLWithPath: _directory.stringValue];
	if ([p runModal] == NSModalResponseOK)
		_directory.stringValue = p.URL.path;
}

- (void)addToHistory:(NSComboBox*)combo max:(int)max
{
	NSString* v = combo.stringValue;
	if (!v.length)
		return;
	NSMutableArray* items = [combo.objectValues mutableCopy];
	[items removeObject: v];
	[items insertObject: v atIndex: 0];
	while ((int)items.count > max)
		[items removeLastObject];
	[combo removeAllItems];
	[combo addItemsWithObjectValues: items];
	combo.stringValue = v;
}

- (void)updateCombos
{
	NppSettings& s = NppSettings::instance();
	[self addToHistory: _findWhat max: s._nbMaxFindHistoryFind];
	if (!_replaceWith.hidden)
		[self addToHistory: _replaceWith max: s._nbMaxFindHistoryReplace];
	if (!_filters.hidden)
	{
		[self addToHistory: _filters max: s._nbMaxFindHistoryFilter];
		[self addToHistory: _directory max: s._nbMaxFindHistoryPath];
	}
	[self saveSettings];
}

#pragma mark - Status line

- (void)setStatus:(const std::string&)msg status:(FindStatus)st tooltip:(const std::string&)tip
{
	_status.stringValue = ns(msg);
	_status.toolTip = tip.empty() ? nil : ns(tip);
	switch (st)
	{
		case FSNotFound: _status.textColor = NSColor.systemRedColor; break;
		case FSEndReached:
		case FSTopReached: _status.textColor = NSColor.systemGreenColor; break;
		case FSMessage: _status.textColor = NSColor.systemBlueColor; break;
		default: _status.textColor = NSColor.labelColor; break;
	}
	if (!tip.empty())
		_status.stringValue = [_status.stringValue stringByAppendingString: @"  ⓘ"];
}

- (void)reportCount:(int)nb prefix:(NSString*)prefix one:(NSString*)one opt:(const FindOption&)opt
{
	if (nb == FIND_INVALID_REGULAR_EXPRESSION)
	{
		[self setStatus: "Find: Invalid Regular Expression" status: FSNotFound tooltip: ""];
		return;
	}
	NSString* r = nb == 1 ? one : [NSString stringWithFormat: prefix, (long)nb];
	r = [NSString stringWithFormat: @"%@ %s", r, Searching::scopeInfo(opt).c_str()];
	bool lax = opt._isWrapAround && !opt._isMatchCase && !opt._isWholeWord;
	std::string reason;
	if (nb == 0 && !lax)
		reason = Searching::noFoundPotentialReason;
	else if (opt._regexEmptyStringFound)
		reason = Searching::regexEmptyFoundReason;
	[self setStatus: str(r) status: FSMessage tooltip: reason];
}

#pragma mark - Actions: Find / Replace

- (void)doFindNext:(id)sender
{
	BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
	[self updateCombos];
	FindOption opt = [self currentOptions];
	if (shift)
		opt._whichDirection = !opt._whichDirection;
	[self saveInMacro: IDOK type: FR_OP_FIND opt: opt];
	FindStatus st;
	ScintillaView* ed = [_host currentEditor];
	bool found = _engine.processFindNext(ed, opt._str2Search, opt, &st);
	if (found && st == FSEndReached)
		[self setStatus: "Find: Reached document end, first occurrence from the top found." status: FSEndReached tooltip: ""];
	else if (found && st == FSTopReached)
		[self setStatus: "Find:  Reached document beginning, first occurrence from the bottom found." status: FSTopReached tooltip: ""];
}

- (void)doCount:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDCCOUNTALL type: FR_OP_FIND opt: opt];
	int nb = _engine.processAll([_host currentEditor], ProcessCountAll, opt, false);
	[self reportCount: nb prefix: @"Count: %ld matches" one: @"Count: 1 match" opt: opt];
}

- (void)doReplace:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDREPLACE type: FR_OP_REPLACE opt: opt];
	_engine.processReplace([_host currentEditor], [_host currentDocumentIsReadOnly], opt._str2Search, opt._str4Replace, opt,
	                       NppSettings::instance()._replaceStopsWithoutFindingNext);
}

- (void)doReplaceAll:(id)sender
{
	[self updateCombos];
	if ([_host currentDocumentIsReadOnly])
	{
		[self setStatus: "Replace All: Cannot replace text. The current document is read only." status: FSNotFound tooltip: ""];
		return;
	}
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDREPLACEALL type: FR_OP_REPLACE opt: opt];
	ScintillaView* ed = [_host currentEditor];
	[ed message: SCI_BEGINUNDOACTION];
	int nb = _engine.processAll(ed, ProcessReplaceAll, opt, false);
	[ed message: SCI_ENDUNDOACTION];
	if (nb == FIND_INVALID_REGULAR_EXPRESSION)
	{
		[self setStatus: "Find: Invalid Regular Expression" status: FSNotFound tooltip: ""];
		return;
	}
	if (nb > 0)
		[_host documentsModifiedByReplace];
	NSString* r = nb == 1 ? @"Replace All: 1 occurrence was replaced" : [NSString stringWithFormat: @"Replace All: %d occurrences were replaced", nb];
	bool lax = opt._isWrapAround && !opt._isMatchCase && !opt._isWholeWord;
	[self setStatus: str([NSString stringWithFormat: @"%@ %s", r, Searching::scopeInfo(opt).c_str()]) status: FSMessage
	        tooltip: (nb == 0 && !lax) ? Searching::noFoundPotentialReason : ""];
}

- (BOOL)confirm:(NSString*)message
{
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = message;
	[a addButtonWithTitle: @"OK"];
	[a addButtonWithTitle: @"Cancel"];
	return [a runModal] == NSAlertFirstButtonReturn;
}

- (void)doReplaceAllOpened:(id)sender
{
	[self updateCombos];
	if (NppSettings::instance()._confirmReplaceInAllOpenDocs && ![self confirm: @"Are you sure you want to replace all occurrences in all open documents?"])
		return;
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDC_REPLACE_OPENEDFILES type: FR_OP_REPLACE + FR_OP_GLOBAL opt: opt];
	opt._isInSelection = false;
	__block int total = 0;
	__block BOOL invalid = NO;
	[_host forEachOpenDocument: ^(ScintillaView* view, NSString* name, BOOL readOnly, BOOL* modified) {
		if (readOnly || invalid)
			return;
		FindOption o = opt;
		[view message: SCI_BEGINUNDOACTION];
		int nb = self->_engine.processAll(view, ProcessReplaceAll, o, true);
		[view message: SCI_ENDUNDOACTION];
		if (nb == FIND_INVALID_REGULAR_EXPRESSION)
			invalid = YES;
		else if (nb > 0)
		{
			total += nb;
			*modified = YES;
		}
	}];
	if (invalid)
	{
		[self setStatus: "Find: Invalid Regular Expression" status: FSNotFound tooltip: ""];
		return;
	}
	[_host documentsModifiedByReplace];
	NSString* r = total == 1 ? @"Replace in Opened Files: 1 occurrence was replaced" : [NSString stringWithFormat: @"Replace in Opened Files: %d occurrences were replaced", total];
	[self setStatus: str(r) status: FSMessage tooltip: ""];
}

#pragma mark - Actions: Find All

// Runs a Find All over a set of documents into the search results window.
- (int)findAllInto:(NppFinder*)finder opt:(FindOption&)opt entire:(BOOL)entire
          runner:(void (^)(void (^each)(ScintillaView* view, NSString* name)))runner searched:(int*)searched
{
	[finder beginNewFilesSearch];
	[finder addSearchLine: opt._str2Search];
	__block int total = 0;
	__block int count = 0;
	__block BOOL invalid = NO;
	FindOption* pOpt = &opt;
	runner(^(ScintillaView* view, NSString* name) {
		if (invalid)
			return;
		++count;
		std::string fileName = str(name);
		bool titleAdded = false;
		int nb = self->_engine.processAll(view, ProcessFindAll, *pOpt, entire, [&](const FoundHit& hit) {
			if (!titleAdded)
			{
				[finder addFileNameTitle: fileName];
				titleAdded = true;
			}
			[finder addHit: hit file: fileName];
		});
		if (nb == FIND_INVALID_REGULAR_EXPRESSION)
			invalid = YES;
		else if (nb > 0)
		{
			[finder addFileHitCount: nb];
			total += nb;
		}
	});
	[finder finishFilesSearch: total searched: count entire: entire options: opt];
	if (searched)
		*searched = count;
	if (invalid)
	{
		[self setStatus: "Find: Invalid Regular Expression" status: FSNotFound tooltip: ""];
		return FIND_INVALID_REGULAR_EXPRESSION;
	}
	return total;
}

- (void)doFindAllCurrent:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDC_FINDALL_CURRENTFILE type: FR_OP_FIND + FR_OP_GLOBAL opt: opt];
	NppFinder* finder = [_host showFinder];
	ScintillaView* ed = [_host currentEditor];
	BOOL entire = !opt._isInSelection;
	NSString* name = [_host currentDocumentPath] ?: [_host currentDocumentName];
	int nb = [self findAllInto: finder opt: opt entire: entire runner: ^(void (^each)(ScintillaView*, NSString*)) {
		each(ed, name);
	} searched: nullptr];
	if (nb > 0)
		[self.window orderOut: nil];
}

- (void)doFindAllOpened:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDC_FINDALL_OPENEDFILES type: FR_OP_FIND + FR_OP_GLOBAL opt: opt];
	opt._isInSelection = false;
	NppFinder* finder = [_host showFinder];
	id<NppFindHost> host = _host;
	int nb = [self findAllInto: finder opt: opt entire: YES runner: ^(void (^each)(ScintillaView*, NSString*)) {
		[host forEachOpenDocument: ^(ScintillaView* view, NSString* n, BOOL readOnly, BOOL* modified) {
			each(view, n);
		}];
	} searched: nullptr];
	if (nb > 0)
		[self.window orderOut: nil];
}

- (NSArray<NSString*>*)filesForFindInFiles:(FindOption&)opt
{
	NSString* dir = ns(opt._directory);
	BOOL isDir = NO;
	if (!dir.length || ![NSFileManager.defaultManager fileExistsAtPath: dir isDirectory: &isDir] || !isDir)
	{
		[self setStatus: "Find in Files: The directory does not exist." status: FSNotFound tooltip: ""];
		return nil;
	}
	auto patterns = splitPatterns(opt._filters);
	if (allPatternsAreExclusion(patterns))
		patterns.push_back("*.*");
	NSMutableArray* files = [NSMutableArray array];
	getMatchedFileNames(dir, 0, patterns, files, opt._isRecursive, opt._isInHiddenDir);
	return files;
}

- (void)doFindInFiles:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDD_FINDINFILES_FIND_BUTTON type: FR_OP_FIND + FR_OP_FIF opt: opt];
	opt._isInSelection = false;
	NSArray* files = [self filesForFindInFiles: opt];
	if (!files)
		return;
	NppFinder* finder = [_host showFinder];
	id<NppFindHost> host = _host;
	int nb = [self findAllInto: finder opt: opt entire: YES runner: ^(void (^each)(ScintillaView*, NSString*)) {
		for (NSString* f in files)
		{
			@autoreleasepool
			{
				[host withFile: f run: ^(ScintillaView* view, BOOL* modified) {
					each(view, f);
				}];
			}
		}
	} searched: nullptr];
	if (nb > 0)
		[self.window orderOut: nil];
}

- (void)doReplaceInFiles:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDD_FINDINFILES_REPLACEINFILES type: FR_OP_REPLACE + FR_OP_FIF opt: opt];
	opt._isInSelection = false;
	NSArray* files = [self filesForFindInFiles: opt];
	if (!files)
		return;
	if (![self confirm: [NSString stringWithFormat: @"Are you sure you want to replace all occurrences in:\r%@\rfor file type:\r%@",
	                     _directory.stringValue, _filters.stringValue.length ? _filters.stringValue : @"*.*"]])
		return;

	int total = 0;

	for (NSString* f in files)
	{
		__block int nb = 0;
		[_host withFile: f run: ^(ScintillaView* view, BOOL* modified) {
			FindOption o = opt;
			[view message: SCI_BEGINUNDOACTION];
			nb = self->_engine.processAll(view, ProcessReplaceAll, o, true);
			[view message: SCI_ENDUNDOACTION];
			if (nb > 0)
				*modified = YES;
		}];
		if (nb == FIND_INVALID_REGULAR_EXPRESSION)
		{
			[self setStatus: "Find: Invalid Regular Expression" status: FSNotFound tooltip: ""];
			return;
		}
		if (nb > 0)
		{
			total += nb;

		}
	}
	[_host documentsModifiedByReplace];
	NSString* r = total == 1 ? @"Replace in Files: 1 occurrence was replaced"
	                         : [NSString stringWithFormat: @"Replace in Files: %d occurrences were replaced", total];
	[self setStatus: str(r) status: FSMessage tooltip: ""];
}

#pragma mark - Actions: Mark

- (void)doMarkAll:(id)sender
{
	[self updateCombos];
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDCMARKALL type: FR_OP_FIND opt: opt];
	int nb = _engine.processAll([_host currentEditor], ProcessMarkAll, opt, false);
	[self reportCount: nb prefix: @"Mark: %ld matches" one: @"Mark: 1 match" opt: opt];
}

- (void)doClearMarks:(id)sender
{
	FindOption opt = [self currentOptions];
	[self saveInMacro: IDC_CLEAR_ALL type: FR_OP_FIND opt: opt];
	_engine.clearMarks([_host currentEditor], opt);
}

- (void)doCopyMarked:(id)sender
{
	[NSApp sendAction: @selector(nppCommand:) to: nil from: [self commandSender: IDM_SEARCH_MARKEDTOCLIP]];
}

- (NSMenuItem*)commandSender:(int)cmd
{
	NSMenuItem* mi = [[NSMenuItem alloc] init];
	mi.tag = cmd;
	return mi;
}

#pragma mark - Commands without the dialog

- (void)findNext:(BOOL)forward
{
	if (!_findWhat.stringValue.length)
	{
		[self showDialog: NppFindDialogFind];
		return;
	}
	FindOption opt = [self currentOptions];
	opt._isInSelection = false;
	opt._whichDirection = forward ? DIR_DOWN : DIR_UP;
	FindStatus st;
	_engine.processFindNext([_host currentEditor], opt._str2Search, opt, &st);
}

- (void)selectAndFindNext:(BOOL)forward
{
	ScintillaView* ed = [_host currentEditor];
	long s = [ed message: SCI_GETSELECTIONSTART];
	long e = [ed message: SCI_GETSELECTIONEND];
	if (s == e)
	{
		long pos = [ed message: SCI_GETCURRENTPOS];
		s = [ed message: SCI_WORDSTARTPOSITION wParam: pos lParam: 1];
		e = [ed message: SCI_WORDENDPOSITION wParam: pos lParam: 1];
		if (s == e)
			return;
		[ed message: SCI_SETSEL wParam: s lParam: e];
	}
	_findWhat.stringValue = [self textFrom: ed start: s end: e];
	[self updateCombos];
	[self findNext: forward];
}

- (void)volatileFindNext:(BOOL)forward
{
	// Uses the selection/word without touching the dialog's history.
	ScintillaView* ed = [_host currentEditor];
	long s = [ed message: SCI_GETSELECTIONSTART];
	long e = [ed message: SCI_GETSELECTIONEND];
	if (s == e)
	{
		long pos = [ed message: SCI_GETCURRENTPOS];
		s = [ed message: SCI_WORDSTARTPOSITION wParam: pos lParam: 1];
		e = [ed message: SCI_WORDENDPOSITION wParam: pos lParam: 1];
		if (s == e)
			return;
		[ed message: SCI_SETSEL wParam: s lParam: e];
	}
	FindOption opt;
	opt._isWholeWord = false;
	opt._isMatchCase = false;
	opt._isWrapAround = true;
	opt._whichDirection = forward ? DIR_DOWN : DIR_UP;
	opt._searchType = FindNormal;
	FindStatus st;
	_engine.processFindNext(ed, str([self textFrom: ed start: s end: e]), opt, &st);
}

#pragma mark - Scripted use (tests, macros)

- (void)setDirectory:(NSString*)dir filters:(NSString*)filters
{
	_directory.stringValue = dir ?: @"";
	_filters.stringValue = filters ?: @"";
}

- (void)setReplaceText:(NSString*)text
{
	_replaceWith.stringValue = text ?: @"";
}

- (void)execDialogCommand:(int)idc
{
	switch (idc)
	{
		case IDOK: [self doFindNext: nil]; break;
		case IDCCOUNTALL: [self doCount: nil]; break;
		case IDC_FINDALL_CURRENTFILE: [self doFindAllCurrent: nil]; break;
		case IDC_FINDALL_OPENEDFILES: [self doFindAllOpened: nil]; break;
		case IDREPLACE: [self doReplace: nil]; break;
		case IDREPLACEALL: [self doReplaceAll: nil]; break;
		case IDC_REPLACE_OPENEDFILES: [self doReplaceAllOpened: nil]; break;
		case IDD_FINDINFILES_FIND_BUTTON: [self doFindInFiles: nil]; break;
		case IDD_FINDINFILES_REPLACEINFILES: [self doReplaceInFiles: nil]; break;
		case IDCMARKALL: [self doMarkAll: nil]; break;
		case IDC_CLEAR_ALL: [self doClearMarks: nil]; break;
	}
}

#pragma mark - Macros

namespace
{
	const int FR_OP_FIND = 1;
	const int FR_OP_REPLACE = 2;
	const int FR_OP_FIF = 4;
	const int FR_OP_GLOBAL = 8;
}

// Port of FindReplaceDlg::saveInMacro: records the search as mtSavedSnR steps.
- (void)saveInMacro:(int)cmd type:(int)cmdType opt:(const FindOption&)o
{
	if (!_macroRecorder)
		return;
	auto saveInt = [&](int what, long v) { _macroRecorder(what, v, nil); };
	auto saveStr = [&](int what, const std::string& v) { _macroRecorder(what, 0, [NSString stringWithUTF8String: v.c_str()] ?: @""); };
	int booleans = 0;
	saveInt(IDC_FRCOMMAND_INIT, 0);
	saveStr(IDFINDWHAT, cmd == IDC_CLEAR_ALL ? "" : o._str2Search);
	booleans |= o._isWholeWord ? IDF_WHOLEWORD : 0;
	booleans |= o._isMatchCase ? IDF_MATCHCASE : 0;
	booleans |= o._dotMatchesNewline ? IDF_REDOTMATCHNL : 0;

	saveInt(IDNORMAL, o._searchType);
	if (cmd == IDCMARKALL)
	{
		booleans |= o._doPurge ? IDF_PURGE_CHECK : 0;
		booleans |= o._doMarkLine ? IDF_MARKLINE_CHECK : 0;
	}
	if (cmdType & FR_OP_REPLACE)
		saveStr(IDREPLACEWITH, o._str4Replace);
	if (cmdType & FR_OP_FIF)
	{
		saveStr(IDD_FINDINFILES_DIR_COMBO, o._directory);
		saveStr(IDD_FINDINFILES_FILTERS_COMBO, o._filters);
		booleans |= o._isRecursive ? IDF_FINDINFILES_RECURSIVE_CHECK : 0;
		booleans |= o._isInHiddenDir ? IDF_FINDINFILES_INHIDDENDIR_CHECK : 0;
	}
	else if (!(cmdType & FR_OP_GLOBAL))
	{
		booleans |= o._isInSelection ? IDF_IN_SELECTION_CHECK : 0;
		booleans |= o._isWrapAround ? IDF_WRAP : 0;
		booleans |= o._whichDirection ? IDF_WHICH_DIRECTION : 0;
	}
	else if (cmdType == FR_OP_FIND + FR_OP_GLOBAL)
	{
		booleans |= o._isInSelection ? IDF_IN_SELECTION_CHECK : 0;
	}
	if (cmd == IDC_CLEAR_ALL)
	{
		booleans = o._doMarkLine ? IDF_MARKLINE_CHECK : 0;
		booleans |= o._isInSelection ? IDF_IN_SELECTION_CHECK : 0;
	}
	saveInt(IDC_FRCOMMAND_BOOLEANS, booleans);
	saveInt(IDC_FRCOMMAND_EXEC, cmd);
}

// Port of FindReplaceDlg::execSavedCommand.
- (void)execSavedCommand:(int)cmd intValue:(long)intValue string:(NSString*)stringValue
{
	std::string str = stringValue.UTF8String ?: "";
	if (cmd != IDC_FRCOMMAND_INIT && !_env)
		return;
	switch (cmd)
	{
		case IDC_FRCOMMAND_INIT:
			_env = std::make_unique<FindOption>();
			break;
		case IDFINDWHAT:
			_env->_str2Search = str;
			break;
		case IDC_FRCOMMAND_BOOLEANS:
			_env->_isWholeWord = (intValue & IDF_WHOLEWORD) > 0;
			_env->_isMatchCase = (intValue & IDF_MATCHCASE) > 0;
			_env->_isRecursive = (intValue & IDF_FINDINFILES_RECURSIVE_CHECK) > 0;
			_env->_isInHiddenDir = (intValue & IDF_FINDINFILES_INHIDDENDIR_CHECK) > 0;
			_env->_doPurge = (intValue & IDF_PURGE_CHECK) > 0;
			_env->_doMarkLine = (intValue & IDF_MARKLINE_CHECK) > 0;
			_env->_isInSelection = (intValue & IDF_IN_SELECTION_CHECK) > 0;
			_env->_isWrapAround = (intValue & IDF_WRAP) > 0;
			_env->_whichDirection = (intValue & IDF_WHICH_DIRECTION) > 0;
			_env->_dotMatchesNewline = (intValue & IDF_REDOTMATCHNL) > 0;
			break;
		case IDNORMAL:
			_env->_searchType = static_cast<SearchType>(intValue);
			break;
		case IDREPLACEWITH:
			_env->_str4Replace = str;
			break;
		case IDD_FINDINFILES_DIR_COMBO:
			_env->_directory = str;
			break;
		case IDD_FINDINFILES_FILTERS_COMBO:
			_env->_filters = str;
			break;
		case IDC_FRCOMMAND_EXEC:
		{
			int exec = static_cast<int>(intValue);
			// 7.5.5 - 7.8.4 macros: IDC_FINDNEXT / IDC_FINDPREV.
			if (exec == IDC_FINDNEXT || exec == IDC_FINDPREV)
			{
				_env->_whichDirection = exec == IDC_FINDNEXT ? DIR_DOWN : DIR_UP;
				exec = IDOK;
			}
			auto recorder = _macroRecorder;
			_macroRecorder = nil;
			_savedEnv = _env.get();
			if (exec == IDOK)
			{
				FindStatus st;
				_engine.processFindNext([_host currentEditor], _env->_str2Search, *_env, &st);
			}
			else
				[self execDialogCommand: exec];
			_savedEnv = nullptr;
			_macroRecorder = recorder;
			break;
		}
	}
}

#pragma mark - Keyboard

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)sel
{
	// Shift+Enter in "Find what" searches backwards, Enter runs the default button.
	if (sel == @selector(insertNewline:) || sel == @selector(insertLineBreak:))
	{
		if (_type == NppFindDialogFind || _type == NppFindDialogReplace)
			[self doFindNext: nil];
		else if (_type == NppFindDialogFindInFiles)
			[self doFindInFiles: nil];
		else
			[self doMarkAll: nil];
		return YES;
	}
	return NO;
}

@end
