#import "NppFinder.h"

#include "NppUpstream.h"
#include "LangManager.h"

#include <algorithm>

namespace
{
	enum { searchHeaderLevel = SC_FOLDLEVELBASE, fileHeaderLevel, resultLevel };

	struct FoundInfo
	{
		std::vector<std::pair<intptr_t, intptr_t>> ranges;
		size_t lineNumber = 0;
		std::string fullPath;
	};

	std::string commafy(long n)
	{
		std::string s = std::to_string(n);
		for (int i = static_cast<int>(s.size()) - 3; i > 0; i -= 3)
			s.insert(i, ",");
		return s;
	}

	int nbDigits(size_t n)
	{
		int d = 1;
		while (n >= 10) { n /= 10; ++d; }
		return d;
	}
}

@interface NppFinder () <ScintillaNotificationProtocol>
@end

@implementation NppFinder
{
	ScintillaView* _view;
	NSTextField* _caption;

	std::vector<FoundInfo> _foundInfos[2];
	std::vector<SearchResultMarkingLine> _markings[2];
	int _main;
	SearchResultMarkings _markingsStruct;

	intptr_t _lastSearchHeaderPos;
	intptr_t _lastFileHeaderPos;
	intptr_t _previousLineNumber;
	int _nbFoundFiles;
	std::string _pendingText;
	std::string _currentFile;
	BOOL _wrapLongLines;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super initWithFrame: frame]))
	{
		_main = 0;
		_previousLineNumber = -1;
		_markingsStruct = {0, nullptr};
		[self buildUI];
	}
	return self;
}

- (ScintillaView*)view
{
	return _view;
}

- (void)buildUI
{
	// Caption bar, like Notepad++'s docking panel title.
	NSView* bar = [[NSView alloc] init];
	bar.translatesAutoresizingMaskIntoConstraints = NO;
	_caption = [NSTextField labelWithString: @"Search results"];
	_caption.font = [NSFont systemFontOfSize: 11];
	_caption.translatesAutoresizingMaskIntoConstraints = NO;
	NSButton* close = [NSButton buttonWithTitle: @"✕" target: self action: @selector(closePanel:)];
	close.bordered = NO;
	close.font = [NSFont systemFontOfSize: 11];
	close.translatesAutoresizingMaskIntoConstraints = NO;
	[bar addSubview: _caption];
	[bar addSubview: close];

	_view = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 400, 150)];
	_view.delegate = self;
	_view.translatesAutoresizingMaskIntoConstraints = NO;

	[self addSubview: bar];
	[self addSubview: _view];
	[NSLayoutConstraint activateConstraints: @[
		[bar.topAnchor constraintEqualToAnchor: self.topAnchor],
		[bar.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
		[bar.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
		[bar.heightAnchor constraintEqualToConstant: 20],
		[_caption.leadingAnchor constraintEqualToAnchor: bar.leadingAnchor constant: 6],
		[_caption.centerYAnchor constraintEqualToAnchor: bar.centerYAnchor],
		[close.trailingAnchor constraintEqualToAnchor: bar.trailingAnchor constant: -4],
		[close.centerYAnchor constraintEqualToAnchor: bar.centerYAnchor],
		[_view.topAnchor constraintEqualToAnchor: bar.bottomAnchor],
		[_view.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
		[_view.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
		[_view.bottomAnchor constraintEqualToAnchor: self.bottomAnchor],
	]];

	[_view message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
	[_view message: SCI_SETEOLMODE wParam: SC_EOL_CRLF];
	[_view message: SCI_SETUNDOCOLLECTION wParam: 0];
	[_view message: SCI_SETCARETLINEVISIBLE wParam: 1];
	[_view message: SCI_SETMARGINWIDTHN wParam: 0 lParam: 0];
	[_view message: SCI_SETMARGINWIDTHN wParam: 1 lParam: 0];
	[_view message: SCI_SETMARGINTYPEN wParam: 2 lParam: SC_MARGIN_SYMBOL];
	[_view message: SCI_SETMARGINMASKN wParam: 2 lParam: SC_MASK_FOLDERS];
	[_view message: SCI_SETMARGINWIDTHN wParam: 2 lParam: 14];
	[_view message: SCI_SETMARGINSENSITIVEN wParam: 2 lParam: 1];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPEN lParam: SC_MARK_BOXMINUS];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDER lParam: SC_MARK_BOXPLUS];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERSUB lParam: SC_MARK_VLINE];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERTAIL lParam: SC_MARK_LCORNER];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEREND lParam: SC_MARK_BOXPLUSCONNECTED];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPENMID lParam: SC_MARK_BOXMINUSCONNECTED];
	[_view message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERMIDTAIL lParam: SC_MARK_TCORNER];
	[_view message: SCI_SETAUTOMATICFOLD wParam: SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
	[_view message: SCI_SETREADONLY wParam: 1];
	[self applyStyles];
	_view.menu = [self contextMenu];
}

- (void)applyStyles
{
	LangManager::instance().apply(_view, LangManager::instance().languageByName("searchResult"));
	[_view setLexerProperty: @"fold" value: @"1"];
	[self publishMarkings];
}

- (void)publishMarkings
{
	// The searchResult lexer reads hit positions through this pointer property.
	char ptrword[sizeof(void*) * 2 + 3];
	snprintf(ptrword, sizeof(ptrword), "%p", static_cast<void*>(&_markingsStruct));
	[_view setLexerProperty: @"@MarkingsStruct" value: [NSString stringWithUTF8String: ptrword]];
}

- (void)setReadOnly:(BOOL)ro
{
	[_view message: SCI_SETREADONLY wParam: ro];
}

- (void)addText:(const std::string&)s
{
	[self setReadOnly: NO];
	[_view message: SCI_ADDTEXT wParam: s.size() lParam: reinterpret_cast<sptr_t>(s.data())];
	[self setReadOnly: YES];
}

- (void)insertText:(const std::string&)s at:(intptr_t)pos
{
	[self setReadOnly: NO];
	[_view message: SCI_INSERTTEXT wParam: pos lParam: reinterpret_cast<sptr_t>(s.c_str())];
	[self setReadOnly: YES];
}

#pragma mark - Building results

- (void)beginNewFilesSearch
{
	if (_purgeBeforeSearch)
		[self removeAll];
	[_view message: SCI_SETSEL wParam: 0 lParam: 0];
	_main = 1 - _main;
	_nbFoundFiles = 0;

	// Fold all old searches (1st level only).
	long lines = [_view message: SCI_GETLINECOUNT];
	for (long l = 0; l < lines; ++l)
	{
		int level = (int)[_view message: SCI_GETFOLDLEVEL wParam: l];
		if ((level & SC_FOLDLEVELHEADERFLAG) && (level & SC_FOLDLEVELNUMBERMASK) == searchHeaderLevel)
			[_view message: SCI_FOLDLINE wParam: l lParam: SC_FOLDACTION_CONTRACT];
	}
}

- (void)addSearchLine:(const std::string&)searchName
{
	std::string one = searchName;
	one.erase(std::remove(one.begin(), one.end(), '\r'), one.end());
	one.erase(std::remove(one.begin(), one.end(), '\n'), one.end());
	[self addText: "Search \"" + one + "\" \r\n"];
	_lastSearchHeaderPos = [_view message: SCI_GETCURRENTPOS] - 2;
	_foundInfos[_main].push_back({});
	_markings[_main].push_back({});
	_previousLineNumber = -1;
}

- (void)addFileNameTitle:(const std::string&)fileName
{
	[self addText: "  " + fileName + "\r\n"];
	_lastFileHeaderPos = [_view message: SCI_GETCURRENTPOS] - 2;
	_foundInfos[_main].push_back({});
	_markings[_main].push_back({});
	_previousLineNumber = -1;
	_currentFile = fileName;
}

- (void)addHit:(const FoundHit&)hit file:(const std::string&)fullPath
{
	// Notepad++ default: one entry per found line, extra hits only add markings.
	bool isRepeatedLine = false;
	if (_previousLineNumber == -1)
		_previousLineNumber = hit.lineNumber;
	else if (_previousLineNumber == (intptr_t)hit.lineNumber)
		isRepeatedLine = true;
	else
		_previousLineNumber = hit.lineNumber;

	std::string header = "\tLine ";
	size_t totalDigits = nbDigits(hit.totalLineNumber) + 1;
	size_t curDigits = nbDigits(hit.lineNumber) + 1;
	header.append(totalDigits - curDigits, ' ');
	header += std::to_string(hit.lineNumber);
	header += ": ";

	std::pair<intptr_t, intptr_t> seg(hit.markStart + header.size(), hit.markEnd + header.size());
	std::string line = header + hit.lineText + "\r\n";

	if (isRepeatedLine && ((intptr_t)line.size() < SC_SEARCHRESULT_LINEBUFFERMAXLENGTH || seg.second < SC_SEARCHRESULT_LINEBUFFERMAXLENGTH))
	{
		_markings[_main].back()._segmentPostions.push_back(seg);
		_foundInfos[_main].back().ranges.push_back({hit.start, hit.end});
		return;
	}

	FoundInfo fi;
	fi.ranges.push_back({hit.start, hit.end});
	fi.lineNumber = hit.lineNumber;
	fi.fullPath = fullPath;
	_foundInfos[_main].push_back(fi);

	if (line.size() >= SC_SEARCHRESULT_LINEBUFFERMAXLENGTH)
	{
		const char* endOfLongLine = " ...\r\n";
		size_t cut = SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - strlen(endOfLongLine) - 1;
		while (cut > 0 && (static_cast<unsigned char>(line[cut]) & 0xC0) == 0x80)
			--cut;
		line = line.substr(0, cut) + endOfLongLine;
	}

	SearchResultMarkingLine ml;
	ml._segmentPostions.push_back(seg);
	_markings[_main].push_back(ml);
	_pendingText += line;
	if (_pendingText.size() > FINDTEMPSTRING_MAXSIZE)
	{
		[self addText: _pendingText];
		_pendingText.clear();
	}
}

- (void)addFileHitCount:(int)count
{
	if (!_pendingText.empty())
	{
		[self addText: _pendingText];
		_pendingText.clear();
	}
	std::string text = count == 1 ? " (1 hit)" : " (" + std::to_string(count) + " hits)";
	[self insertText: text at: _lastFileHeaderPos];
	++_nbFoundFiles;
}

- (void)finishFilesSearch:(int)count searched:(int)searchedCount entire:(BOOL)entire options:(const FindOption&)opt
{
	if (!_pendingText.empty())
	{
		[self addText: _pendingText];
		_pendingText.clear();
	}

	// New results go on top of the older ones.
	int old = 1 - _main;
	_foundInfos[old].insert(_foundInfos[old].begin(), _foundInfos[_main].begin(), _foundInfos[_main].end());
	_markings[old].insert(_markings[old].begin(), _markings[_main].begin(), _markings[_main].end());
	_foundInfos[_main].clear();
	_markings[_main].clear();
	_main = old;

	_markingsStruct._length = static_cast<intptr_t>(_markings[_main].size());
	_markingsStruct._markings = _markings[_main].empty() ? nullptr : _markings[_main].data();

	std::string hitsIn = count == 1 ? "hit" : "hits";
	std::string fileOrSelection = entire ? "file" : "selection";
	if (_nbFoundFiles != 1)
		fileOrSelection += "s";
	std::string text = "(" + commafy(count) + " " + hitsIn + " in " + commafy(_nbFoundFiles) + " " + fileOrSelection +
	                   " of " + commafy(searchedCount) + " searched)";

	std::string mode = opt._searchType == FindExtended ? "Extended" : opt._searchType == FindRegex ? "RegEx" : "Normal";
	if (opt._searchType == FindRegex && opt._dotMatchesNewline)
		mode += ".";
	std::string options;
	if (opt._isMatchCase)
		options += "Case";
	if (opt._isWholeWord)
	{
		if (!options.empty())
			options += "/";
		options += "Word";
	}
	if (!options.empty())
		mode += ": ";
	text += " [" + mode + options + "]";

	[self insertText: text at: _lastSearchHeaderPos];
	[_view message: SCI_SETSEL wParam: 0 lParam: 0];
	[self publishMarkings];
	[_view setLexerProperty: @"fold" value: @"1"];
	[_view message: SCI_COLOURISE wParam: 0 lParam: -1];
	_previousLineNumber = -1;

	_caption.stringValue = [NSString stringWithFormat: @"Search results - (%d %s)", count, count == 1 ? "hit" : "hits"];
}

- (void)removeAll
{
	_foundInfos[0].clear();
	_foundInfos[1].clear();
	_markings[0].clear();
	_markings[1].clear();
	_markingsStruct = {0, nullptr};
	[self setReadOnly: NO];
	[_view message: SCI_CLEARALL];
	[self setReadOnly: YES];
	_caption.stringValue = @"Search results";
}

#pragma mark - Navigation

- (const FoundInfo*)infoForLine:(long)lno
{
	const auto& infos = _foundInfos[_main];
	if (lno < 0 || lno >= (long)infos.size() || infos[lno].ranges.empty())
		return nullptr;
	return &infos[lno];
}

- (void)gotoFoundLine:(long)lno occurrence:(size_t)index
{
	const FoundInfo* fi = [self infoForLine: lno];
	if (!fi)
		return;
	ScintillaView* editor = [_delegate finder: self openDocument: [NSString stringWithUTF8String: fi->fullPath.c_str()]];
	if (!editor)
		return;
	if (index >= fi->ranges.size())
		index = 0;
	Searching::displaySectionCentered(editor, fi->ranges[index].first, fi->ranges[index].second);

	// Highlight the hit in the results too.
	const auto& ml = _markings[_main][lno];
	if (index < ml._segmentPostions.size())
	{
		long ls = [_view message: SCI_POSITIONFROMLINE wParam: lno];
		long le = [_view message: SCI_GETLINEENDPOSITION wParam: lno];
		long b = ls + ml._segmentPostions[index].first;
		long e = std::min<long>(ls + ml._segmentPostions[index].second, le);
		if (b < e)
		{
			[_view message: SCI_SETSEL wParam: b lParam: e];
			[_view message: SCI_SCROLLRANGE wParam: b lParam: e];
		}
	}
}

- (void)gotoNextFoundResult:(int)direction
{
	long total = [_view message: SCI_GETLINECOUNT];
	if (total <= 1)
		return;

	long pos = [_view message: SCI_GETCURRENTPOS];
	long lno = [_view message: SCI_LINEFROMPOSITION wParam: pos];
	long posInLine = pos - [_view message: SCI_POSITIONFROMLINE wParam: lno];

	// Next occurrence on the same line first.
	if (const FoundInfo* fi = [self infoForLine: lno])
	{
		const auto& segs = _markings[_main][lno]._segmentPostions;
		if (direction >= 0)
		{
			for (size_t i = 0; i < segs.size(); ++i)
				if (segs[i].first > posInLine || (segs[i].first == posInLine && [_view message: SCI_GETSELECTIONEMPTY]))
				{
					[self gotoFoundLine: lno occurrence: i];
					return;
				}
		}
		else
		{
			long selStart = [_view message: SCI_GETSELECTIONSTART] - [_view message: SCI_POSITIONFROMLINE wParam: lno];
			for (size_t i = segs.size(); i-- > 0;)
				if (segs[i].first < selStart)
				{
					[self gotoFoundLine: lno occurrence: i];
					return;
				}
		}
		(void)fi;
	}

	// Then the next/previous result line inside the current search, wrapping around.
	long minL = lno;
	while (minL > 0 && ([_view message: SCI_GETFOLDLEVEL wParam: minL] & SC_FOLDLEVELNUMBERMASK) != searchHeaderLevel)
		--minL;
	long maxL = [_view message: SCI_GETLASTCHILD wParam: minL lParam: searchHeaderLevel];
	if (maxL < minL)
		maxL = total - 1;

	long l = lno;
	for (long n = 0; n <= maxL - minL + 1; ++n)
	{
		l += direction >= 0 ? 1 : -1;
		if (l > maxL)
			l = minL;
		if (l < minL)
			l = maxL;
		if ([self infoForLine: l])
		{
			[_view message: SCI_ENSUREVISIBLE wParam: l];
			size_t occ = direction >= 0 ? 0 : _markings[_main][l]._segmentPostions.size() - 1;
			[self gotoFoundLine: l occurrence: occ];
			return;
		}
	}
}

#pragma mark - Scintilla notifications

- (void)notification:(SCNotification*)n
{
	if (n->nmhdr.code != SCN_DOUBLECLICK)
		return;
	long lno = n->line;
	if ([_view message: SCI_GETFOLDLEVEL wParam: lno] & SC_FOLDLEVELHEADERFLAG)
	{
		[_view message: SCI_TOGGLEFOLD wParam: lno];
		return;
	}

	// Which occurrence on the line was clicked.
	long posInLine = n->position - [_view message: SCI_POSITIONFROMLINE wParam: lno];
	size_t index = 0;
	if (lno < (long)_markings[_main].size())
	{
		const auto& segs = _markings[_main][lno]._segmentPostions;
		for (; index < segs.size(); ++index)
			if (segs[index].first <= posInLine && posInLine <= segs[index].second)
				break;
		if (index >= segs.size())
			index = 0;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[self gotoFoundLine: lno occurrence: index];
	});
}

#pragma mark - Context menu (Finder's popup in Notepad++)

- (NSMenu*)contextMenu
{
	NSMenu* m = [[NSMenu alloc] init];
	auto add = [&](NSString* t, SEL s) { [m addItemWithTitle: t action: s keyEquivalent: @""].target = self; };
	add(@"Fold all", @selector(foldAll:));
	add(@"Unfold all", @selector(unfoldAll:));
	[m addItem: NSMenuItem.separatorItem];
	add(@"Copy Selected Line(s)", @selector(copyLines:));
	add(@"Copy Selected Pathname(s)", @selector(copyPathnames:));
	add(@"Select all", @selector(selectAllResults:));
	add(@"Clear all", @selector(clearAll:));
	[m addItem: NSMenuItem.separatorItem];
	add(@"Open Selected Pathname(s)", @selector(openAll:));
	[m addItem: NSMenuItem.separatorItem];
	add(@"Word wrap long lines", @selector(toggleWrap:));
	add(@"Purge for every search", @selector(togglePurge:));
	[m addItem: NSMenuItem.separatorItem];
	add(@"Close", @selector(closePanel:));
	return m;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if (item.action == @selector(toggleWrap:))
		item.state = _wrapLongLines ? NSControlStateValueOn : NSControlStateValueOff;
	else if (item.action == @selector(togglePurge:))
		item.state = _purgeBeforeSearch ? NSControlStateValueOn : NSControlStateValueOff;
	return YES;
}

- (void)foldAll:(id)sender   { [_view message: SCI_FOLDALL wParam: SC_FOLDACTION_CONTRACT]; }
- (void)unfoldAll:(id)sender { [_view message: SCI_FOLDALL wParam: SC_FOLDACTION_EXPAND]; }
- (void)selectAllResults:(id)sender { [_view message: SCI_SELECTALL]; }
- (void)clearAll:(id)sender  { [self removeAll]; }
- (void)closePanel:(id)sender { [_delegate finderDidRequestClose: self]; }

- (void)toggleWrap:(id)sender
{
	_wrapLongLines = !_wrapLongLines;
	[_view message: SCI_SETWRAPMODE wParam: _wrapLongLines ? SC_WRAP_WORD : SC_WRAP_NONE];
}

- (void)togglePurge:(id)sender
{
	_purgeBeforeSearch = !_purgeBeforeSearch;
}

- (NSString*)lineText:(long)l
{
	long s = [_view message: SCI_POSITIONFROMLINE wParam: l];
	long e = [_view message: SCI_GETLINEENDPOSITION wParam: l];
	std::string buf(e - s + 1, '\0');
	Sci_TextRangeFull tr{{s, e}, buf.data()};
	[_view message: SCI_GETTEXTRANGEFULL wParam: 0 lParam: reinterpret_cast<sptr_t>(&tr)];
	buf.resize(e - s);
	return [NSString stringWithUTF8String: buf.c_str()] ?: @"";
}

- (void)selectedLineRange:(long*)from to:(long*)to
{
	*from = [_view message: SCI_LINEFROMPOSITION wParam: [_view message: SCI_GETSELECTIONSTART]];
	*to = [_view message: SCI_LINEFROMPOSITION wParam: [_view message: SCI_GETSELECTIONEND]];
	if ([_view message: SCI_GETSELECTIONEMPTY] || *from == *to)
	{
		int level = (int)[_view message: SCI_GETFOLDLEVEL wParam: *from] & SC_FOLDLEVELNUMBERMASK;
		if (level != resultLevel)
			*to = [_view message: SCI_GETLASTCHILD wParam: *from lParam: level];
	}
}

- (void)copyLines:(id)sender
{
	long from, to;
	[self selectedLineRange: &from to: &to];
	NSMutableArray* lines = [NSMutableArray array];
	NSString* previous = @"";
	for (long l = from; l <= to; ++l)
	{
		NSString* s = [self lineText: l];
		if (![s hasPrefix: @"\t"] || [s isEqualToString: previous])
			continue;
		previous = s;
		NSRange colon = [s rangeOfString: @":"];
		[lines addObject: colon.location == NSNotFound ? s : [s substringFromIndex: MIN(colon.location + 2, s.length)]];
	}
	if (!lines.count)
		return;
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard setString: [[lines componentsJoinedByString: @"\n"] stringByAppendingString: @"\n"] forType: NSPasteboardTypeString];
}

- (NSArray<NSString*>*)selectedPaths
{
	long from, to;
	[self selectedLineRange: &from to: &to];
	NSMutableOrderedSet* paths = [NSMutableOrderedSet orderedSet];
	for (long l = from; l <= to; ++l)
		if (const FoundInfo* fi = [self infoForLine: l])
			[paths addObject: [NSString stringWithUTF8String: fi->fullPath.c_str()]];
	return paths.array;
}

- (void)copyPathnames:(id)sender
{
	NSArray* paths = [self selectedPaths];
	if (!paths.count)
		return;
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard setString: [[paths componentsJoinedByString: @"\n"] stringByAppendingString: @"\n"] forType: NSPasteboardTypeString];
}

- (void)openAll:(id)sender
{
	for (NSString* p in [self selectedPaths])
		[_delegate finder: self openDocument: p];
}

@end
