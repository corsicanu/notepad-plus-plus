// Command dispatch by Notepad++ command ID: the macOS counterpart of
// PowerEditor's NppCommands.cpp. Each ported command registers a handler;
// menu items whose command has no handler are shown disabled.

#import "NppMainWindowInternal.h"
#import "NppFindCharsInRange.h"
#import "NppStyleConfigurator.h"

#include "LangManager.h"
#include "NppSettings.h"
#include "NppUpstream.h"
#include "EncodingMapper.h"

#include <functional>
#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

@interface NppMainWindow (CommandsInternal)
+ (const std::unordered_map<int, NppCommandHandler>&)commandTable;
- (void)toggleLineComment;
- (void)convertEOL:(NppEOL)eol;
- (void)encodeIn:(int)cmd;
- (void)encodeInCodepage:(int)cmd;
- (void)convertTo:(int)cmd;
- (void)markAllWithStyle:(int)ind;
- (void)jumpToBookmark:(BOOL)forward;
- (void)changeHistoryGoTo:(BOOL)next;
- (void)moveCurrentTab:(int)delta;
@end

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	std::string textRange(ScintillaView* v, long s, long e)
	{
		if (e <= s)
			return "";
		std::string buf(e - s + 1, '\0');
		Sci_TextRangeFull tr{{s, e}, buf.data()};
		sci(v, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
		buf.resize(e - s);
		return buf;
	}

	void toClipboard(const std::string& s)
	{
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString: [NSString stringWithUTF8String: s.c_str()] ?: @"" forType: NSPasteboardTypeString];
	}

	std::string eolString(ScintillaView* v)
	{
		switch (sci(v, SCI_GETEOLMODE))
		{
			case SC_EOL_CRLF: return "\r\n";
			case SC_EOL_CR: return "\r";
			default: return "\n";
		}
	}

	int markExtStyle(int n) // 1..5 -> indicator
	{
		static const int styles[] = {SCE_UNIVERSAL_FOUND_STYLE_EXT1, SCE_UNIVERSAL_FOUND_STYLE_EXT2, SCE_UNIVERSAL_FOUND_STYLE_EXT3,
		                             SCE_UNIVERSAL_FOUND_STYLE_EXT4, SCE_UNIVERSAL_FOUND_STYLE_EXT5};
		return styles[n - 1];
	}

	void clearIndicator(ScintillaView* v, int ind)
	{
		sci(v, SCI_SETINDICATORCURRENT, ind);
		sci(v, SCI_INDICATORCLEARRANGE, 0, sci(v, SCI_GETLENGTH));
	}

	// Port of Notepad_plus::goToNextIndicator / goToPreviousIndicator.
	void goToIndicator(ScintillaView* v, int ind, bool next)
	{
		long len = sci(v, SCI_GETLENGTH);
		long pos = next ? sci(v, SCI_GETSELECTIONEND) : sci(v, SCI_GETSELECTIONSTART);
		auto hasInd = [&](long p) { return sci(v, SCI_INDICATORVALUEAT, ind, p) != 0; };
		long start = -1, end = -1;
		if (next)
		{
			long p = hasInd(pos) ? sci(v, SCI_INDICATOREND, ind, pos) : pos;
			if (p < len && !hasInd(p))
				p = sci(v, SCI_INDICATOREND, ind, p);
			if (p >= len || !hasInd(p))
			{
				// wrap
				p = hasInd(0) ? 0 : sci(v, SCI_INDICATOREND, ind, 0);
				if (p >= len || !hasInd(p))
					return;
			}
			start = p;
			end = sci(v, SCI_INDICATOREND, ind, p);
		}
		else
		{
			long p = pos > 0 ? pos - 1 : 0;
			if (hasInd(p))
				p = sci(v, SCI_INDICATORSTART, ind, p) - 1;
			while (p >= 0 && !hasInd(p))
				p = sci(v, SCI_INDICATORSTART, ind, p) - 1;
			if (p < 0)
			{
				p = len - 1;
				while (p >= 0 && !hasInd(p))
					p = sci(v, SCI_INDICATORSTART, ind, p) - 1;
				if (p < 0)
					return;
			}
			start = sci(v, SCI_INDICATORSTART, ind, p);
			end = sci(v, SCI_INDICATOREND, ind, p);
		}
		Searching::displaySectionCentered(v, start, end, next);
	}

	std::string styledText(ScintillaView* v, const std::vector<int>& inds)
	{
		std::string out;
		std::string eol = eolString(v);
		long len = sci(v, SCI_GETLENGTH);
		// Collect ranges of every requested indicator, in document order.
		std::vector<std::pair<long, long>> ranges;
		for (int ind : inds)
		{
			long p = 0;
			while (p < len)
			{
				if (sci(v, SCI_INDICATORVALUEAT, ind, p))
				{
					long e = sci(v, SCI_INDICATOREND, ind, p);
					ranges.push_back({p, e});
					p = e;
				}
				else
				{
					long e = sci(v, SCI_INDICATOREND, ind, p);
					p = e > p ? e : len;
				}
			}
		}
		std::sort(ranges.begin(), ranges.end());
		for (const auto& r : ranges)
		{
			out += textRange(v, r.first, r.second);
			out += eol;
		}
		return out;
	}

	// Lines carrying a bookmark, from bottom to top.
	std::vector<long> bookmarkedLines(ScintillaView* v)
	{
		std::vector<long> lines;
		long l = sci(v, SCI_MARKERNEXT, 0, 1 << MARK_BOOKMARK);
		while (l >= 0)
		{
			lines.push_back(l);
			l = sci(v, SCI_MARKERNEXT, l + 1, 1 << MARK_BOOKMARK);
		}
		return lines;
	}

	std::string lineWithEol(ScintillaView* v, long l)
	{
		return textRange(v, sci(v, SCI_POSITIONFROMLINE, l), sci(v, SCI_POSITIONFROMLINE, l + 1) >= 0 ? sci(v, SCI_POSITIONFROMLINE, l + 1) : sci(v, SCI_GETLENGTH));
	}

	void deleteLines(ScintillaView* v, const std::vector<long>& lines)
	{
		sci(v, SCI_BEGINUNDOACTION);
		for (auto it = lines.rbegin(); it != lines.rend(); ++it)
		{
			long s = sci(v, SCI_POSITIONFROMLINE, *it);
			long e = sci(v, SCI_POSITIONFROMLINE, *it + 1);
			if (e < 0 || *it + 1 >= sci(v, SCI_GETLINECOUNT))
			{
				// last line: also remove the preceding EOL
				e = sci(v, SCI_GETLENGTH);
				if (*it > 0)
					s = sci(v, SCI_GETLINEENDPOSITION, *it - 1);
			}
			sci(v, SCI_DELETERANGE, s, e - s);
		}
		sci(v, SCI_ENDUNDOACTION);
	}

	void foldLevel(ScintillaView* v, int level2Collapse, bool collapse)
	{
		sci(v, SCI_COLOURISE, 0, -1);
		long maxLine = sci(v, SCI_GETLINECOUNT);
		for (long line = 0; line < maxLine; ++line)
		{
			long level = sci(v, SCI_GETFOLDLEVEL, line);
			if (level & SC_FOLDLEVELHEADERFLAG)
			{
				level -= SC_FOLDLEVELBASE;
				if (level2Collapse == (level & SC_FOLDLEVELNUMBERMASK))
					sci(v, SCI_FOLDLINE, line, collapse ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND);
			}
		}
	}

	void foldCurrent(ScintillaView* v, bool collapse)
	{
		long line = sci(v, SCI_LINEFROMPOSITION, sci(v, SCI_GETCURRENTPOS));
		long header = (sci(v, SCI_GETFOLDLEVEL, line) & SC_FOLDLEVELHEADERFLAG) ? line : sci(v, SCI_GETFOLDPARENT, line);
		if (header >= 0)
			sci(v, SCI_FOLDLINE, header, collapse ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND);
	}

	// Notepad++ "Select All In-between {} [] or ()".
	void selectMatchingBraces(ScintillaView* v)
	{
		long pos = sci(v, SCI_GETCURRENTPOS);
		auto isBrace = [](int c) { return c && std::strchr("()[]{}", c); };
		long braceAt = -1;
		if (pos > 0 && isBrace((int)sci(v, SCI_GETCHARAT, pos - 1)))
			braceAt = pos - 1;
		else if (isBrace((int)sci(v, SCI_GETCHARAT, pos)))
			braceAt = pos;
		if (braceAt < 0)
			return;
		long match = sci(v, SCI_BRACEMATCH, braceAt);
		if (match < 0)
			return;
		long a = std::min(braceAt, match), b = std::max(braceAt, match);
		sci(v, SCI_SETSEL, a, b + 1);
	}

	void goToMatchingBrace(ScintillaView* v)
	{
		long pos = sci(v, SCI_GETCURRENTPOS);
		auto isBrace = [](int c) { return c && std::strchr("()[]{}", c); };
		long braceAt = -1;
		if (pos > 0 && isBrace((int)sci(v, SCI_GETCHARAT, pos - 1)))
			braceAt = pos - 1;
		else if (isBrace((int)sci(v, SCI_GETCHARAT, pos)))
			braceAt = pos;
		if (braceAt < 0)
			return;
		long match = sci(v, SCI_BRACEMATCH, braceAt);
		if (match >= 0)
			sci(v, SCI_GOTOPOS, match);
	}

	std::string dateTime(bool longFormat)
	{
		NSDateFormatter* f = [[NSDateFormatter alloc] init];
		f.dateStyle = longFormat ? NSDateFormatterLongStyle : NSDateFormatterShortStyle;
		f.timeStyle = NSDateFormatterShortStyle;
		// Notepad++: "time date" order.
		NSDateFormatter* t = [[NSDateFormatter alloc] init];
		t.timeStyle = NSDateFormatterShortStyle;
		t.dateStyle = NSDateFormatterNoStyle;
		NSDateFormatter* d = [[NSDateFormatter alloc] init];
		d.dateStyle = longFormat ? NSDateFormatterFullStyle : NSDateFormatterShortStyle;
		d.timeStyle = NSDateFormatterNoStyle;
		NSDate* now = [NSDate date];
		return std::string([NSString stringWithFormat: @"%@ %@", [t stringFromDate: now], [d stringFromDate: now]].UTF8String);
	}
}

@implementation NppMainWindow (Commands)

+ (const std::unordered_map<int, NppCommandHandler>&)commandTable
{
	static std::unordered_map<int, NppCommandHandler> t;
	if (!t.empty())
		return t;

	// ---- File ----
	t[IDM_FILE_NEW] = ^(NppMainWindow* w) { [w newDocument]; };
	t[IDM_FILE_OPEN] = ^(NppMainWindow* w) { [w openDocument]; };
	t[IDM_FILE_OPEN_FOLDER] = ^(NppMainWindow* w) {
		if (NSString* p = w.currentBuffer.path)
			[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs: @[[NSURL fileURLWithPath: p]]];
	};
	t[IDM_FILE_OPEN_CMD] = ^(NppMainWindow* w) {
		NSString* dir = w.currentBuffer.path.stringByDeletingLastPathComponent ?: NSHomeDirectory();
		NSURL* terminal = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier: @"com.apple.Terminal"];
		[NSWorkspace.sharedWorkspace openURLs: @[[NSURL fileURLWithPath: dir]] withApplicationAtURL: terminal
		                        configuration: [NSWorkspaceOpenConfiguration configuration] completionHandler: nil];
	};
	t[IDM_FILE_OPEN_DEFAULT_VIEWER] = ^(NppMainWindow* w) {
		if (NSString* p = w.currentBuffer.path)
			[NSWorkspace.sharedWorkspace openURL: [NSURL fileURLWithPath: p]];
	};
	t[IDM_FILE_RELOAD] = ^(NppMainWindow* w) { [w reloadCurrent]; };
	t[IDM_FILE_SAVE] = ^(NppMainWindow* w) { [w saveBuffer: w.currentBuffer as: NO]; };
	t[IDM_FILE_SAVEAS] = ^(NppMainWindow* w) { [w saveBuffer: w.currentBuffer as: YES]; };
	t[IDM_FILE_SAVECOPYAS] = ^(NppMainWindow* w) { [w saveCopyOf: w.currentBuffer]; };
	t[IDM_FILE_SAVEALL] = ^(NppMainWindow* w) {
		NppBuffer* cur = w.currentBuffer;
		for (NppBuffer* b in [w.buffers copy])
			if (b.dirty && ![w saveBuffer: b as: NO])
				break;
		[w activateBuffer: [w.buffers indexOfObject: cur]];
	};
	t[IDM_FILE_RENAME] = ^(NppMainWindow* w) { [w renameCurrent]; };
	t[IDM_FILE_CLOSE] = ^(NppMainWindow* w) { [w closeBufferAtIndex: w.currentIndex force: NO]; };
	t[IDM_FILE_CLOSEALL] = ^(NppMainWindow* w) {
		if (![w confirmCloseAll])
			return;
		while (w.buffers.count > 1)
			[w closeBufferAtIndex: w.buffers.count - 1 force: YES];
		[w closeBufferAtIndex: 0 force: YES];
	};
	auto closeWhere = [](NppMainWindow* w, BOOL (^keep)(NppBuffer* b, NSInteger idx)) {
		NSMutableArray* toClose = [NSMutableArray array];
		NSInteger cur = w.currentIndex;
		for (NSInteger i = 0; i < (NSInteger)w.buffers.count; ++i)
			if (!keep(w.buffers[i], i - cur))
				[toClose addObject: w.buffers[i]];
		if (![w confirmCloseBuffers: toClose])
			return;
		for (NppBuffer* b in toClose)
			[w closeBufferAtIndex: [w.buffers indexOfObject: b] force: YES];
	};
	t[IDM_FILE_CLOSEALL_BUT_CURRENT] = ^(NppMainWindow* w) { closeWhere(w, ^BOOL(NppBuffer*, NSInteger rel) { return rel == 0; }); };
	t[IDM_FILE_CLOSEALL_TOLEFT] = ^(NppMainWindow* w) { closeWhere(w, ^BOOL(NppBuffer*, NSInteger rel) { return rel >= 0; }); };
	t[IDM_FILE_CLOSEALL_TORIGHT] = ^(NppMainWindow* w) { closeWhere(w, ^BOOL(NppBuffer*, NSInteger rel) { return rel <= 0; }); };
	t[IDM_FILE_CLOSEALL_BUT_PINNED] = ^(NppMainWindow* w) { closeWhere(w, ^BOOL(NppBuffer* b, NSInteger) { return b.pinned; }); };
	t[IDM_FILE_CLOSEALL_UNCHANGED] = ^(NppMainWindow* w) { closeWhere(w, ^BOOL(NppBuffer* b, NSInteger) { return b.dirty || !b.path; }); };
	t[IDM_FILE_DELETE] = ^(NppMainWindow* w) { [w deleteCurrentFile]; };
	t[IDM_FILE_LOADSESSION] = ^(NppMainWindow* w) {
		NSOpenPanel* p = [NSOpenPanel openPanel];
		if ([p runModal] == NSModalResponseOK)
			[w loadSessionFromPath: p.URL.path];
	};
	t[IDM_FILE_SAVESESSION] = ^(NppMainWindow* w) {
		NSSavePanel* p = [NSSavePanel savePanel];
		p.nameFieldStringValue = @"session.xml";
		if ([p runModal] == NSModalResponseOK)
			[w saveSessionToPath: p.URL.path withBackups: NO];
	};
	t[IDM_FILE_EXIT] = ^(NppMainWindow* w) { [NSApp terminate: nil]; };
	t[IDM_FILE_RESTORELASTCLOSEDFILE] = ^(NppMainWindow* w) { [w restoreLastClosedFile]; };
	t[IDM_OPEN_ALL_RECENT_FILE] = ^(NppMainWindow* w) { [w openPaths: [NppMainWindow recentFiles]]; };
	t[IDM_CLEAN_RECENT_FILE_LIST] = ^(NppMainWindow* w) { [NppMainWindow clearRecentFiles]; };

	// ---- Edit ----
	// Main-menu items use the responder chain; context menus and the toolbar come here.
	t[IDM_EDIT_UNDO] = ^(NppMainWindow* w) { sci(w.editor, SCI_UNDO); };
	t[IDM_EDIT_REDO] = ^(NppMainWindow* w) { sci(w.editor, SCI_REDO); };
	t[IDM_EDIT_CUT] = ^(NppMainWindow* w) { sci(w.editor, SCI_CUT); };
	t[IDM_EDIT_COPY] = ^(NppMainWindow* w) { sci(w.editor, SCI_COPY); };
	t[IDM_EDIT_PASTE] = ^(NppMainWindow* w) { sci(w.editor, SCI_PASTE); };
	t[IDM_EDIT_DELETE] = ^(NppMainWindow* w) { sci(w.editor, SCI_CLEAR); };
	t[IDM_EDIT_SELECTALL] = ^(NppMainWindow* w) { sci(w.editor, SCI_SELECTALL); };
	t[IDM_EDIT_TOGGLESYSTEMREADONLY] = ^(NppMainWindow* w) {
		// macOS counterpart of the Windows read-only attribute: the user write permission bit.
		NppBuffer* b = w.currentBuffer;
		if (!b.path)
			return;
		NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath: b.path error: nil];
		short perm = [attrs[NSFilePosixPermissions] shortValue];
		BOOL ro = (perm & 0200) != 0;
		perm = ro ? (perm & ~0222) : (perm | 0200);
		if ([NSFileManager.defaultManager setAttributes: @{NSFilePosixPermissions: @(perm)} ofItemAtPath: b.path error: nil])
		{
			b.fileReadOnly = ro;
			sci(w.editor, SCI_SETREADONLY, b.readOnly || b.fileReadOnly);
			[w refreshTabs];
		}
	};
	t[IDM_EDIT_INS_TAB] = ^(NppMainWindow* w) { sci(w.editor, SCI_TAB); };
	t[IDM_EDIT_RMV_TAB] = ^(NppMainWindow* w) { sci(w.editor, SCI_BACKTAB); };
	t[IDM_EDIT_DUP_LINE] = ^(NppMainWindow* w) { sci(w.editor, SCI_LINEDUPLICATE); };
	t[IDM_EDIT_TRANSPOSE_LINE] = ^(NppMainWindow* w) { sci(w.editor, SCI_LINETRANSPOSE); };
	t[IDM_EDIT_SPLIT_LINES] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		sci(v, SCI_TARGETFROMSELECTION);
		long edge = sci(v, SCI_GETEDGECOLUMN);
		sci(v, SCI_LINESSPLIT, edge > 0 ? sci(v, SCI_TEXTWIDTH, STYLE_DEFAULT, reinterpret_cast<sptr_t>("P")) * edge : 0);
	};
	t[IDM_EDIT_JOIN_LINES] = ^(NppMainWindow* w) {
		sci(w.editor, SCI_TARGETFROMSELECTION);
		sci(w.editor, SCI_LINESJOIN);
	};
	t[IDM_EDIT_LINE_UP] = ^(NppMainWindow* w) { sci(w.editor, SCI_MOVESELECTEDLINESUP); };
	t[IDM_EDIT_LINE_DOWN] = ^(NppMainWindow* w) { sci(w.editor, SCI_MOVESELECTEDLINESDOWN); };
	t[IDM_EDIT_UPPERCASE] = ^(NppMainWindow* w) { sci(w.editor, SCI_UPPERCASE); };
	t[IDM_EDIT_LOWERCASE] = ^(NppMainWindow* w) { sci(w.editor, SCI_LOWERCASE); };
	t[IDM_EDIT_BLOCK_COMMENT] = ^(NppMainWindow* w) { [w toggleLineComment]; };
	t[IDM_EDIT_FULLPATHTOCLIP] = ^(NppMainWindow* w) { toClipboard((w.currentBuffer.path ?: w.currentBuffer.displayName).UTF8String); };
	t[IDM_EDIT_FILENAMETOCLIP] = ^(NppMainWindow* w) { toClipboard(w.currentBuffer.displayName.UTF8String); };
	t[IDM_EDIT_CURRENTDIRTOCLIP] = ^(NppMainWindow* w) {
		if (w.currentBuffer.path)
			toClipboard(w.currentBuffer.path.stringByDeletingLastPathComponent.UTF8String);
	};
	t[IDM_EDIT_COPY_ALL_NAMES] = ^(NppMainWindow* w) {
		NSMutableArray* a = [NSMutableArray array];
		for (NppBuffer* b in w.buffers)
			[a addObject: b.displayName];
		toClipboard([a componentsJoinedByString: @"\n"].UTF8String);
	};
	t[IDM_EDIT_COPY_ALL_PATHS] = ^(NppMainWindow* w) {
		NSMutableArray* a = [NSMutableArray array];
		for (NppBuffer* b in w.buffers)
			[a addObject: b.path ?: b.displayName];
		toClipboard([a componentsJoinedByString: @"\n"].UTF8String);
	};
	t[IDM_EDIT_INSERT_DATETIME_SHORT] = ^(NppMainWindow* w) {
		std::string s = dateTime(false);
		sci(w.editor, SCI_REPLACESEL, 0, reinterpret_cast<sptr_t>(s.c_str()));
	};
	t[IDM_EDIT_INSERT_DATETIME_LONG] = ^(NppMainWindow* w) {
		std::string s = dateTime(true);
		sci(w.editor, SCI_REPLACESEL, 0, reinterpret_cast<sptr_t>(s.c_str()));
	};
	t[IDM_EDIT_TOGGLEREADONLY] = ^(NppMainWindow* w) {
		NppBuffer* b = w.currentBuffer;
		b.readOnly = !b.readOnly;
		sci(w.editor, SCI_SETREADONLY, b.readOnly);
		[w refreshTabs];
	};
	t[IDM_FORMAT_TODOS] = ^(NppMainWindow* w) { [w convertEOL: NppEOLWindows]; };
	t[IDM_FORMAT_TOUNIX] = ^(NppMainWindow* w) { [w convertEOL: NppEOLUnix]; };
	t[IDM_FORMAT_TOMAC] = ^(NppMainWindow* w) { [w convertEOL: NppEOLMac]; };

	// ---- Search ----
	t[IDM_SEARCH_FIND] = ^(NppMainWindow* w) { [w.findReplaceDlg showDialog: NppFindDialogFind]; };
	t[IDM_SEARCH_REPLACE] = ^(NppMainWindow* w) { [w.findReplaceDlg showDialog: NppFindDialogReplace]; };
	t[IDM_SEARCH_FINDINFILES] = ^(NppMainWindow* w) { [w.findReplaceDlg showDialog: NppFindDialogFindInFiles]; };
	t[IDM_SEARCH_MARK] = ^(NppMainWindow* w) { [w.findReplaceDlg showDialog: NppFindDialogMark]; };
	t[IDM_SEARCH_FINDNEXT] = ^(NppMainWindow* w) { [w.findReplaceDlg findNext: YES]; };
	t[IDM_SEARCH_FINDPREV] = ^(NppMainWindow* w) { [w.findReplaceDlg findNext: NO]; };
	t[IDM_SEARCH_SETANDFINDNEXT] = ^(NppMainWindow* w) { [w.findReplaceDlg selectAndFindNext: YES]; };
	t[IDM_SEARCH_SETANDFINDPREV] = ^(NppMainWindow* w) { [w.findReplaceDlg selectAndFindNext: NO]; };
	t[IDM_SEARCH_VOLATILE_FINDNEXT] = ^(NppMainWindow* w) { [w.findReplaceDlg volatileFindNext: YES]; };
	t[IDM_SEARCH_VOLATILE_FINDPREV] = ^(NppMainWindow* w) { [w.findReplaceDlg volatileFindNext: NO]; };
	t[IDM_SEARCH_FINDCHARINRANGE] = ^(NppMainWindow* w) {
		static NppFindCharsInRange* dlg = nil;
		if (!dlg)
		{
			__weak NppMainWindow* weak = w;
			dlg = [[NppFindCharsInRange alloc] initWithEditor: ^ScintillaView* { return weak.editor; }];
		}
		[dlg show];
	};
	t[IDM_SEARCH_FINDINCREMENT] = ^(NppMainWindow* w) { [w showIncrementalFind]; };
	t[IDM_SEARCH_GOTOLINE] = ^(NppMainWindow* w) { [w goToLineDialog]; };
	t[IDM_SEARCH_GOTOMATCHINGBRACE] = ^(NppMainWindow* w) { goToMatchingBrace(w.editor); };
	t[IDM_SEARCH_SELECTMATCHINGBRACES] = ^(NppMainWindow* w) { selectMatchingBraces(w.editor); };
	t[IDM_FOCUS_ON_FOUND_RESULTS] = ^(NppMainWindow* w) {
		NppFinder* f = [w showFinder];
		[w.window makeFirstResponder: f.view.content];
	};
	t[IDM_SEARCH_GOTONEXTFOUND] = ^(NppMainWindow* w) {
		if ([w finderVisible])
			[[w showFinder] gotoNextFoundResult: 0];
	};
	t[IDM_SEARCH_GOTOPREVFOUND] = ^(NppMainWindow* w) {
		if ([w finderVisible])
			[[w showFinder] gotoNextFoundResult: -1];
	};
	t[IDM_SEARCH_CHANGED_NEXT] = ^(NppMainWindow* w) { [w changeHistoryGoTo: YES]; };
	t[IDM_SEARCH_CHANGED_PREV] = ^(NppMainWindow* w) { [w changeHistoryGoTo: NO]; };
	t[IDM_SEARCH_CLEAR_CHANGE_HISTORY] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		long pos = sci(v, SCI_GETCURRENTPOS);
		long flags = sci(v, SCI_GETCHANGEHISTORY);
		sci(v, SCI_EMPTYUNDOBUFFER);
		sci(v, SCI_SETCHANGEHISTORY, SC_CHANGE_HISTORY_DISABLED);
		sci(v, SCI_SETCHANGEHISTORY, flags);
		sci(v, SCI_GOTOPOS, pos);
	};

	for (int n = 1; n <= 5; ++n)
	{
		int ind = markExtStyle(n);
		t[IDM_SEARCH_MARKALLEXT1 + (n - 1) * 2] = ^(NppMainWindow* w) { [w markAllWithStyle: ind]; };
		t[IDM_SEARCH_UNMARKALLEXT1 + (n - 1) * 2] = ^(NppMainWindow* w) { clearIndicator(w.editor, ind); };
		t[IDM_SEARCH_GOPREVMARKER1 + (n - 1)] = ^(NppMainWindow* w) { goToIndicator(w.editor, ind, false); };
		t[IDM_SEARCH_GONEXTMARKER1 + (n - 1)] = ^(NppMainWindow* w) { goToIndicator(w.editor, ind, true); };
		t[IDM_SEARCH_STYLE1TOCLIP + (n - 1)] = ^(NppMainWindow* w) { toClipboard(styledText(w.editor, {ind})); };
		t[IDM_SEARCH_MARKONEEXT1 + (n - 1)] = ^(NppMainWindow* w) {
			ScintillaView* v = w.editor;
			long s = sci(v, SCI_GETSELECTIONSTART), e = sci(v, SCI_GETSELECTIONEND);
			if (s == e)
			{
				long pos = sci(v, SCI_GETCURRENTPOS);
				s = sci(v, SCI_WORDSTARTPOSITION, pos, 1);
				e = sci(v, SCI_WORDENDPOSITION, pos, 1);
			}
			if (e > s)
			{
				sci(v, SCI_SETINDICATORCURRENT, ind);
				sci(v, SCI_INDICATORFILLRANGE, s, e - s);
			}
		};
	}
	t[IDM_SEARCH_CLEARALLMARKS] = ^(NppMainWindow* w) {
		for (int n = 1; n <= 5; ++n)
			clearIndicator(w.editor, markExtStyle(n));
	};
	t[IDM_SEARCH_GOPREVMARKER_DEF] = ^(NppMainWindow* w) { goToIndicator(w.editor, SCE_UNIVERSAL_FOUND_STYLE, false); };
	t[IDM_SEARCH_GONEXTMARKER_DEF] = ^(NppMainWindow* w) { goToIndicator(w.editor, SCE_UNIVERSAL_FOUND_STYLE, true); };
	t[IDM_SEARCH_ALLSTYLESTOCLIP] = ^(NppMainWindow* w) {
		toClipboard(styledText(w.editor, {markExtStyle(1), markExtStyle(2), markExtStyle(3), markExtStyle(4), markExtStyle(5)}));
	};
	t[IDM_SEARCH_MARKEDTOCLIP] = ^(NppMainWindow* w) { toClipboard(styledText(w.editor, {SCE_UNIVERSAL_FOUND_STYLE})); };

	// Bookmarks
	t[IDM_SEARCH_TOGGLE_BOOKMARK] = ^(NppMainWindow* w) {
		[w toggleBookmarkAtLine: sci(w.editor, SCI_LINEFROMPOSITION, sci(w.editor, SCI_GETCURRENTPOS))];
	};
	t[IDM_SEARCH_NEXT_BOOKMARK] = ^(NppMainWindow* w) { [w jumpToBookmark: YES]; };
	t[IDM_SEARCH_PREV_BOOKMARK] = ^(NppMainWindow* w) { [w jumpToBookmark: NO]; };
	t[IDM_SEARCH_CLEAR_BOOKMARKS] = ^(NppMainWindow* w) { sci(w.editor, SCI_MARKERDELETEALL, MARK_BOOKMARK); };
	t[IDM_SEARCH_COPYMARKEDLINES] = ^(NppMainWindow* w) {
		std::string s;
		for (long l : bookmarkedLines(w.editor))
			s += lineWithEol(w.editor, l);
		toClipboard(s);
	};
	t[IDM_SEARCH_CUTMARKEDLINES] = ^(NppMainWindow* w) {
		std::string s;
		auto lines = bookmarkedLines(w.editor);
		for (long l : lines)
			s += lineWithEol(w.editor, l);
		toClipboard(s);
		deleteLines(w.editor, lines);
	};
	t[IDM_SEARCH_DELETEMARKEDLINES] = ^(NppMainWindow* w) { deleteLines(w.editor, bookmarkedLines(w.editor)); };
	t[IDM_SEARCH_DELETEUNMARKEDLINES] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		std::vector<long> lines;
		long n = sci(v, SCI_GETLINECOUNT);
		for (long l = 0; l < n; ++l)
			if (!(sci(v, SCI_MARKERGET, l) & (1 << MARK_BOOKMARK)))
				lines.push_back(l);
		deleteLines(v, lines);
	};
	t[IDM_SEARCH_PASTEMARKEDLINES] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		NSString* clip = [NSPasteboard.generalPasteboard stringForType: NSPasteboardTypeString];
		if (!clip)
			return;
		std::string text = clip.UTF8String;
		auto lines = bookmarkedLines(v);
		if (lines.empty())
			return;
		sci(v, SCI_BEGINUNDOACTION);
		for (auto it = lines.rbegin(); it != lines.rend(); ++it)
		{
			long s = sci(v, SCI_POSITIONFROMLINE, *it);
			long e = sci(v, SCI_GETLINEENDPOSITION, *it);
			sci(v, SCI_SETTARGETRANGE, s, e);
			std::string t = text;
			while (!t.empty() && (t.back() == '\n' || t.back() == '\r'))
				t.pop_back();
			sci(v, SCI_REPLACETARGET, t.size(), reinterpret_cast<sptr_t>(t.data()));
		}
		sci(v, SCI_ENDUNDOACTION);
	};
	t[IDM_SEARCH_INVERSEMARKS] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		long n = sci(v, SCI_GETLINECOUNT);
		for (long l = 0; l < n; ++l)
			[w toggleBookmarkAtLine: l];
		(void)v;
	};

	// ---- View ----
	t[IDM_VIEW_WRAP] = ^(NppMainWindow* w) {
		w.wordWrap = !w.wordWrap;
		sci(w.editor, SCI_SETWRAPMODE, w.wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE);
	};
	t[IDM_VIEW_TAB_SPACE] = ^(NppMainWindow* w) {
		BOOL on = sci(w.editor, SCI_GETVIEWWS) != SCWS_INVISIBLE;
		sci(w.editor, SCI_SETVIEWWS, on ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS);
	};
	t[IDM_VIEW_EOL] = ^(NppMainWindow* w) { sci(w.editor, SCI_SETVIEWEOL, !sci(w.editor, SCI_GETVIEWEOL)); };
	t[IDM_VIEW_ALL_CHARACTERS] = ^(NppMainWindow* w) {
		BOOL on = sci(w.editor, SCI_GETVIEWEOL) && sci(w.editor, SCI_GETVIEWWS) != SCWS_INVISIBLE;
		sci(w.editor, SCI_SETVIEWEOL, !on);
		sci(w.editor, SCI_SETVIEWWS, on ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS);
	};
	t[IDM_VIEW_INDENT_GUIDE] = ^(NppMainWindow* w) {
		BOOL on = sci(w.editor, SCI_GETINDENTATIONGUIDES) != SC_IV_NONE;
		sci(w.editor, SCI_SETINDENTATIONGUIDES, on ? SC_IV_NONE : SC_IV_LOOKBOTH);
	};
	t[IDM_VIEW_ZOOMIN] = ^(NppMainWindow* w) { sci(w.editor, SCI_ZOOMIN); };
	t[IDM_VIEW_ZOOMOUT] = ^(NppMainWindow* w) { sci(w.editor, SCI_ZOOMOUT); };
	t[IDM_VIEW_ZOOMRESTORE] = ^(NppMainWindow* w) { sci(w.editor, SCI_SETZOOM, 0); };
	t[IDM_VIEW_FOLDALL] = ^(NppMainWindow* w) { sci(w.editor, SCI_FOLDALL, SC_FOLDACTION_CONTRACT); };
	t[IDM_VIEW_UNFOLDALL] = ^(NppMainWindow* w) { sci(w.editor, SCI_FOLDALL, SC_FOLDACTION_EXPAND); };
	t[IDM_VIEW_FOLD_CURRENT] = ^(NppMainWindow* w) { foldCurrent(w.editor, true); };
	t[IDM_VIEW_UNFOLD_CURRENT] = ^(NppMainWindow* w) { foldCurrent(w.editor, false); };
	for (int n = 1; n <= 8; ++n)
	{
		t[IDM_VIEW_FOLD + n] = ^(NppMainWindow* w) { foldLevel(w.editor, n - 1, true); };
		t[IDM_VIEW_UNFOLD + n] = ^(NppMainWindow* w) { foldLevel(w.editor, n - 1, false); };
	}
	t[IDM_VIEW_TAB_NEXT] = ^(NppMainWindow* w) {
		if (w.buffers.count > 1)
			[w activateBuffer: (w.currentIndex + 1) % w.buffers.count];
	};
	t[IDM_VIEW_TAB_PREV] = ^(NppMainWindow* w) {
		if (w.buffers.count > 1)
			[w activateBuffer: (w.currentIndex + w.buffers.count - 1) % w.buffers.count];
	};
	t[IDM_VIEW_TAB_START] = ^(NppMainWindow* w) { [w activateBuffer: 0]; };
	t[IDM_VIEW_TAB_END] = ^(NppMainWindow* w) { [w activateBuffer: w.buffers.count - 1]; };
	for (int n = 0; n < 9; ++n)
		t[IDM_VIEW_TAB1 + n] = ^(NppMainWindow* w) {
			if (n < (int)w.buffers.count)
				[w activateBuffer: n];
		};
	t[IDM_PINTAB] = ^(NppMainWindow* w) { [w togglePinCurrent]; };
	for (int c = IDM_VIEW_TAB_COLOUR_NONE; c <= IDM_VIEW_TAB_COLOUR_5; ++c)
		t[c] = ^(NppMainWindow* w) { [w setCurrentTabColor: c - IDM_VIEW_TAB_COLOUR_NONE - 1]; };
	t[IDM_VIEW_GOTO_START] = ^(NppMainWindow* w) { [w moveCurrentTabTo: 0]; };
	t[IDM_VIEW_GOTO_END] = ^(NppMainWindow* w) { [w moveCurrentTabTo: w.buffers.count]; };
	t[IDM_VIEW_TAB_MOVEFORWARD] = ^(NppMainWindow* w) { [w moveCurrentTab: 1]; };
	t[IDM_VIEW_TAB_MOVEBACKWARD] = ^(NppMainWindow* w) { [w moveCurrentTab: -1]; };
	t[IDM_VIEW_FULLSCREENTOGGLE] = ^(NppMainWindow* w) { [w.window toggleFullScreen: nil]; };
	t[IDM_VIEW_ALWAYSONTOP] = ^(NppMainWindow* w) {
		w.window.level = w.window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
	};

	// ---- Encoding ----
	for (int id : {IDM_FORMAT_ANSI, IDM_FORMAT_AS_UTF_8, IDM_FORMAT_UTF_8, IDM_FORMAT_UTF_16BE, IDM_FORMAT_UTF_16LE})
		t[id] = ^(NppMainWindow* w) { [w encodeIn: id]; };
	for (int id : {IDM_FORMAT_CONV2_ANSI, IDM_FORMAT_CONV2_AS_UTF_8, IDM_FORMAT_CONV2_UTF_8, IDM_FORMAT_CONV2_UTF_16BE, IDM_FORMAT_CONV2_UTF_16LE})
		t[id] = ^(NppMainWindow* w) { [w convertTo: id]; };
	for (int id = IDM_FORMAT_ENCODE; id <= IDM_FORMAT_ENCODE_END; ++id)
		if (EncodingMapper::getInstance().getEncodingFromIndex(id - IDM_FORMAT_ENCODE) != -1)
			t[id] = ^(NppMainWindow* w) { [w encodeInCodepage: id]; };

	// ---- Language ----
	for (int id = IDM_LANG; id < IDM_LANG + 200; ++id)
	{
		LangType lt = Notepad_plus::menuID2LangType(id);
		if (lt == L_EXTERNAL || (lt == L_TEXT && id != IDM_LANG_TEXT))
			continue;
		if (!LangManager::instance().languageByType(lt))
			continue;
		t[id] = ^(NppMainWindow* w) {
			w.currentBuffer.lang = LangManager::instance().languageByType(lt);
			[w applyLanguage: w.currentBuffer];
		};
	}

	// ---- Settings ----
	t[IDM_LANGSTYLE_CONFIG_DLG] = ^(NppMainWindow*) { [[NppStyleConfigurator shared] show]; };

	// ---- ? ----
	auto openURL = [](NSString* url) {
		return ^(NppMainWindow*) { [NSWorkspace.sharedWorkspace openURL: [NSURL URLWithString: url]]; };
	};
	t[IDM_HOMESWEETHOME] = openURL(@"https://notepad-plus-plus.org/");
	t[IDM_PROJECTPAGE] = openURL(@"https://github.com/notepad-plus-plus/notepad-plus-plus/");
	t[IDM_ONLINEDOCUMENT] = openURL(@"https://npp-user-manual.org/");
	t[IDM_FORUM] = openURL(@"https://community.notepad-plus-plus.org/");
	t[IDM_ABOUT] = ^(NppMainWindow*) { [NSApp orderFrontStandardAboutPanel: nil]; };

	return t;
}

- (BOOL)runCommand:(int)cmd
{
	const auto& table = [NppMainWindow commandTable];
	auto it = table.find(cmd);
	if (it == table.end())
		return NO;
	it->second(self);
	return YES;
}

- (void)nppCommand:(id)sender
{
	[self runCommand: (int)[sender tag]];
}

#pragma mark - Helpers used by commands

- (void)toggleLineComment
{
	NppBuffer* b = [self currentBuffer];
	if (!b.lang || b.lang->commentLine.empty())
	{
		NSBeep();
		return;
	}
	ScintillaView* e = self.editor;
	const std::string& cl = b.lang->commentLine;
	std::string token = cl + " ";
	long startLine = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETSELECTIONSTART));
	long endLine = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETSELECTIONEND));
	if (endLine > startLine && sci(e, SCI_GETSELECTIONEND) == sci(e, SCI_POSITIONFROMLINE, endLine))
		--endLine;

	auto indentPos = [e](long l) { return (long)sci(e, SCI_GETLINEINDENTPOSITION, l); };
	auto hasComment = [&](long l) {
		long p = indentPos(l);
		for (size_t i = 0; i < cl.size(); ++i)
			if (sci(e, SCI_GETCHARAT, p + i) != cl[i])
				return false;
		return true;
	};
	bool allCommented = true;
	for (long l = startLine; l <= endLine; ++l)
		if (indentPos(l) != sci(e, SCI_GETLINEENDPOSITION, l) && !hasComment(l))
			allCommented = false;

	sci(e, SCI_BEGINUNDOACTION);
	for (long l = startLine; l <= endLine; ++l)
	{
		long p = indentPos(l);
		if (p == sci(e, SCI_GETLINEENDPOSITION, l))
			continue;
		if (allCommented)
		{
			long len = cl.size();
			if (sci(e, SCI_GETCHARAT, p + len) == ' ')
				++len;
			sci(e, SCI_DELETERANGE, p, len);
		}
		else
			sci(e, SCI_INSERTTEXT, p, reinterpret_cast<sptr_t>(token.c_str()));
	}
	sci(e, SCI_ENDUNDOACTION);
}

- (void)convertEOL:(NppEOL)eol
{
	NppBuffer* b = [self currentBuffer];
	b.eol = eol;
	sci(self.editor, SCI_CONVERTEOLS, eol);
	sci(self.editor, SCI_SETEOLMODE, eol);
	[self updateStatusBar];
}

// Text codec of a buffer: its codepage, ANSI for uni8Bit/uni7Bit, else UTF-8.
static int textCodepage(NppBuffer* b)
{
	if (b.encoding != -1)
		return b.encoding;
	return (b.unicodeMode == uni8Bit || b.unicodeMode == uni7Bit) ? [NppBuffer ansiCodepage] : SC_CP_UTF8;
}

// Upstream asks before an encoding change that reloads from disk.
- (BOOL)confirmEncodingReload
{
	NppBuffer* b = [self currentBuffer];
	auto ask = [](NSString* title) {
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = title;
		a.informativeText = @"You should save the current modification.\rAll the saved modifications cannot be undone.\r\rContinue?";
		[a addButtonWithTitle: @"Yes"];
		[a addButtonWithTitle: @"No"];
		return [a runModal] == NSAlertFirstButtonReturn;
	};
	if (b.dirty)
	{
		if (!ask(@"Save Current Modification"))
			return NO;
		[self saveBuffer: b as: NO];
		sci(self.editor, SCI_EMPTYUNDOBUFFER);
	}
	if (sci(self.editor, SCI_CANUNDO) && !ask(@"Lose Undo Ability Warning"))
		return NO;
	return YES;
}

// Port of NppCommands IDM_FORMAT_ANSI / AS_UTF_8 / UTF_8 / UTF_16BE / UTF_16LE.
- (void)encodeIn:(int)cmd
{
	NppBuffer* b = [self currentBuffer];
	int originalUm = b.unicodeMode;
	int um;
	bool shouldBeDirty = true;
	switch (cmd)
	{
		case IDM_FORMAT_AS_UTF_8: shouldBeDirty = originalUm != uni8Bit; um = uniUTF8_NoBOM; break;
		case IDM_FORMAT_UTF_8: um = uniUTF8; break;
		case IDM_FORMAT_UTF_16BE: um = uni16BE; break;
		case IDM_FORMAT_UTF_16LE: um = uni16LE; break;
		default: shouldBeDirty = originalUm != uniUTF8_NoBOM; um = uni8Bit; break;
	}

	if (b.encoding != -1)
	{
		if (!b.path || ![self confirmEncodingReload])
			return;
		// Reload the bytes without codepage auto-detection.
		NppSettings& s = NppSettings::instance();
		bool detect = s._detectEncoding;
		s._detectEncoding = false;
		[b loadFromPath: b.path editor: self.editor forcedEncoding: -1 error: nil];
		s._detectEncoding = detect;
		[self activateBuffer: self.currentIndex];
		return;
	}

	if (originalUm == um)
		return;
	// In Notepad++ ANSI documents hold raw bytes, so switching between ANSI and
	// a Unicode mode reinterprets them; here the text is re-decoded instead.
	int from = textCodepage(b);
	b.unicodeMode = um;
	int to = textCodepage(b);
	if (from != to)
		[b reinterpretFromCodepage: from toCodepage: to editor: self.editor];
	if (shouldBeDirty)
		b.dirty = YES;
	[self refreshTabs];
	[self updateTitle];
	[self updateStatusBar];
}

// Port of NppCommands IDM_FORMAT_WIN_1250 ... IDM_FORMAT_KOI8R_CYRILLIC.
- (void)encodeInCodepage:(int)cmd
{
	int encoding = EncodingMapper::getInstance().getEncodingFromIndex(cmd - IDM_FORMAT_ENCODE);
	if (encoding == -1)
		return;
	NppBuffer* b = [self currentBuffer];
	if (!b.path)
	{
		int from = textCodepage(b);
		b.encoding = encoding;
		b.unicodeMode = uniUTF8_NoBOM;
		[b reinterpretFromCodepage: from toCodepage: encoding editor: self.editor];
		[self updateStatusBar];
		return;
	}
	if (![self confirmEncodingReload])
		return;
	if (!b.dirty)
	{
		[b loadFromPath: b.path editor: self.editor forcedEncoding: encoding error: nil];
		[self activateBuffer: self.currentIndex];
	}
}

// Port of NppCommands IDM_FORMAT_CONV2_*: the text stays, the file encoding changes.
- (void)convertTo:(int)cmd
{
	NppBuffer* b = [self currentBuffer];
	int um = 0;
	switch (cmd)
	{
		case IDM_FORMAT_CONV2_ANSI:
			if (b.encoding != -1 || b.unicodeMode == uni8Bit)
				return;
			um = uni8Bit;
			break;
		case IDM_FORMAT_CONV2_AS_UTF_8: um = uniUTF8_NoBOM; break;
		case IDM_FORMAT_CONV2_UTF_8: um = uniUTF8; break;
		case IDM_FORMAT_CONV2_UTF_16BE: um = uni16BE; break;
		case IDM_FORMAT_CONV2_UTF_16LE: um = uni16LE; break;
	}
	if (b.encoding == -1 && b.unicodeMode == um)
		return;
	b.encoding = -1;
	b.unicodeMode = um;
	b.dirty = YES;
	[self refreshTabs];
	[self updateTitle];
	[self updateStatusBar];
}

- (void)markAllWithStyle:(int)ind
{
	NSString* word = [self selectedTextOrWord: YES];
	if (!word.length)
		return;
	const NppSettings& s = NppSettings::instance();
	FindOption opt;
	opt._isMatchCase = s._markAllCaseSensitive;
	opt._isWholeWord = s._markAllWordOnly;
	opt._str2Search = word.UTF8String;
	clearIndicator(self.editor, ind);
	self.findReplaceDlg.engine.processAll(self.editor, ProcessMarkAllExt, opt, true, nullptr, ind);
}

- (void)jumpToBookmark:(BOOL)forward
{
	ScintillaView* e = self.editor;
	long line = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS));
	long found = forward ? sci(e, SCI_MARKERNEXT, line + 1, 1 << MARK_BOOKMARK)
	                     : sci(e, SCI_MARKERPREVIOUS, line - 1, 1 << MARK_BOOKMARK);
	if (found < 0)
		found = forward ? sci(e, SCI_MARKERNEXT, 0, 1 << MARK_BOOKMARK)
		                : sci(e, SCI_MARKERPREVIOUS, sci(e, SCI_GETLINECOUNT), 1 << MARK_BOOKMARK);
	if (found >= 0)
	{
		sci(e, SCI_ENSUREVISIBLEENFORCEPOLICY, found);
		sci(e, SCI_GOTOLINE, found);
	}
}

// Port of Notepad_plus::changedHistoryGoTo.
- (void)changeHistoryGoTo:(BOOL)next
{
	ScintillaView* e = self.editor;
	int mask = (1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
	           (1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);
	long line = -1;
	long blockIndicator = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETCURRENTPOS));
	long lastLine = sci(e, SCI_GETLINECOUNT);

	if (next)
	{
		long currentLine = blockIndicator;
		for (long i = currentLine; i < lastLine; i++)
		{
			if (sci(e, SCI_MARKERGET, i) & mask)
			{
				if (i != blockIndicator)
				{
					line = i;
					break;
				}
				blockIndicator++;
			}
		}
		if (line == -1)
		{
			for (long i = 0; i < currentLine + 1; i++)
				if (sci(e, SCI_MARKERGET, i) & mask)
				{
					line = i;
					break;
				}
		}
	}
	else
	{
		while (true)
		{
			line = sci(e, SCI_MARKERPREVIOUS, blockIndicator, mask);
			if (line == -1 || line != blockIndicator)
				break;
			blockIndicator--;
		}
		if (line == -1)
			line = sci(e, SCI_MARKERPREVIOUS, lastLine - 1, mask);
	}

	if (line != -1)
	{
		sci(e, SCI_ENSUREVISIBLEENFORCEPOLICY, line);
		sci(e, SCI_GOTOLINE, line);
	}
	else
		NSBeep();
}

- (void)moveCurrentTab:(int)delta
{
	NSInteger from = self.currentIndex;
	NSInteger to = from + delta;
	if (to < 0 || to >= (NSInteger)self.buffers.count)
		return;
	NppBuffer* b = self.buffers[from];
	[self.buffers removeObjectAtIndex: from];
	[self.buffers insertObject: b atIndex: to];
	[self activateBuffer: to];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if (item.action != @selector(nppCommand:))
		return [self respondsToSelector: item.action];

	int cmd = (int)item.tag;
	const auto& table = [NppMainWindow commandTable];
	if (table.find(cmd) == table.end())
		return NO;

	NppBuffer* b = [self currentBuffer];
	ScintillaView* e = self.editor;
	auto check = [item](bool on) { item.state = on ? NSControlStateValueOn : NSControlStateValueOff; };

	switch (cmd)
	{
		case IDM_VIEW_WRAP: check(self.wordWrap); break;
		case IDM_VIEW_TAB_SPACE: check(sci(e, SCI_GETVIEWWS) != SCWS_INVISIBLE); break;
		case IDM_VIEW_EOL: check(sci(e, SCI_GETVIEWEOL)); break;
		case IDM_VIEW_ALL_CHARACTERS: check(sci(e, SCI_GETVIEWEOL) && sci(e, SCI_GETVIEWWS) != SCWS_INVISIBLE); break;
		case IDM_VIEW_INDENT_GUIDE: check(sci(e, SCI_GETINDENTATIONGUIDES) != SC_IV_NONE); break;
		case IDM_VIEW_ALWAYSONTOP: check(self.window.level == NSFloatingWindowLevel); break;
		case IDM_VIEW_FULLSCREENTOGGLE: check((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0); break;
		case IDM_EDIT_TOGGLEREADONLY: check(b.readOnly); break;
		case IDM_EDIT_TOGGLESYSTEMREADONLY: check(b.fileReadOnly); return b.path != nil;
		case IDM_PINTAB: item.title = b.pinned ? @"Unpin Tab" : @"Pin Tab"; break;
		case IDM_FORMAT_ANSI: check(b.encoding == -1 && (b.unicodeMode == uni8Bit || b.unicodeMode == uni7Bit)); break;
		case IDM_FORMAT_AS_UTF_8: check(b.encoding == -1 && b.unicodeMode == uniUTF8_NoBOM); break;
		case IDM_FORMAT_UTF_8: check(b.encoding == -1 && b.unicodeMode == uniUTF8); break;
		case IDM_FORMAT_UTF_16BE: check(b.encoding == -1 && (b.unicodeMode == uni16BE || b.unicodeMode == uni16BE_NoBOM)); break;
		case IDM_FORMAT_UTF_16LE: check(b.encoding == -1 && (b.unicodeMode == uni16LE || b.unicodeMode == uni16LE_NoBOM)); break;
		// The current EOL format is shown disabled, as in Notepad++.
		case IDM_FORMAT_TODOS: return b.eol != NppEOLWindows;
		case IDM_FORMAT_TOUNIX: return b.eol != NppEOLUnix;
		case IDM_FORMAT_TOMAC: return b.eol != NppEOLMac;
		case IDM_FILE_RELOAD:
		case IDM_FILE_OPEN_FOLDER:
		case IDM_FILE_OPEN_DEFAULT_VIEWER:
		case IDM_FILE_DELETE:
		case IDM_EDIT_CURRENTDIRTOCLIP:
			return b.path != nil;
		case IDM_FILE_SAVE:
			return b.dirty || !b.path;
		case IDM_SEARCH_GOTONEXTFOUND:
		case IDM_SEARCH_GOTOPREVFOUND:
			return [self finderVisible];
		default:
			if (cmd >= IDM_FORMAT_ENCODE && cmd <= IDM_FORMAT_ENCODE_END)
				check(b.encoding != -1 && EncodingMapper::getInstance().getIndexFromEncoding(b.encoding) == cmd - IDM_FORMAT_ENCODE);
			else if (cmd >= IDM_LANG && cmd < IDM_LANG + 200)
				check(LangManager::instance().langTypeOf(b.lang) == Notepad_plus::menuID2LangType(cmd));
			break;
	}
	return YES;
}

@end
