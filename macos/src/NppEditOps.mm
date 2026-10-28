// Edit menu operations not covered by NppCommands.mm: line sorting (with
// upstream's Sorters.h), duplicate/empty line removal, blank operations,
// case conversions, comments, multi-select and Begin/End Select. Ports of
// the matching cases of NppCommands.cpp / ScintillaEditView.cpp.

#import "NppMainWindowInternal.h"

#include "LangManager.h"
#include "NppSettings.h"
#include "NppSorters.h"
#include "NppUpstream.h"

#include <random>
#include <string>
#include <unordered_set>
#include <vector>

typedef void (^NppCommandHandler)(NppMainWindow* w);

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	std::string range(ScintillaView* v, long s, long e)
	{
		if (e <= s)
			return "";
		std::string buf(e - s + 1, '\0');
		Sci_TextRangeFull tr{{s, e}, buf.data()};
		sci(v, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
		buf.resize(e - s);
		return buf;
	}

	std::wstring toW(const std::string& s)
	{
		NSString* n = [NSString stringWithUTF8String: s.c_str()] ?: @"";
		NSData* d = [n dataUsingEncoding: NSUTF32LittleEndianStringEncoding];
		return std::wstring(reinterpret_cast<const wchar_t*>(d.bytes), d.length / sizeof(wchar_t));
	}

	std::string toU8(const std::wstring& w)
	{
		NSString* n = [[NSString alloc] initWithBytes: w.data() length: w.size() * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding];
		return n ? n.UTF8String : "";
	}

	std::string eol(ScintillaView* v)
	{
		switch (sci(v, SCI_GETEOLMODE))
		{
			case SC_EOL_CRLF: return "\r\n";
			case SC_EOL_CR: return "\r";
			default: return "\n";
		}
	}

	// Lines of the selection (whole document when nothing is selected),
	// like ScintillaEditView::getSelectionLinesRange.
	void lineRange(ScintillaView* v, long& from, long& to)
	{
		long s = sci(v, SCI_GETSELECTIONSTART), e = sci(v, SCI_GETSELECTIONEND);
		if (s == e)
		{
			from = 0;
			to = sci(v, SCI_GETLINECOUNT) - 1;
			// The empty line after a final EOL isn't part of the content.
			if (to > 0 && sci(v, SCI_POSITIONFROMLINE, to) == sci(v, SCI_GETLINEENDPOSITION, to))
				--to;
			return;
		}
		from = sci(v, SCI_LINEFROMPOSITION, s);
		to = sci(v, SCI_LINEFROMPOSITION, e);
		if (to > from && e == sci(v, SCI_POSITIONFROMLINE, to))
			--to;
	}

	std::vector<std::string> getLines(ScintillaView* v, long from, long to)
	{
		std::vector<std::string> lines;
		for (long l = from; l <= to; ++l)
			lines.push_back(range(v, sci(v, SCI_POSITIONFROMLINE, l), sci(v, SCI_GETLINEENDPOSITION, l)));
		return lines;
	}

	void replaceLines(ScintillaView* v, long from, long to, const std::vector<std::string>& lines)
	{
		std::string joined;
		std::string e = eol(v);
		for (size_t i = 0; i < lines.size(); ++i)
		{
			if (i)
				joined += e;
			joined += lines[i];
		}
		long s = sci(v, SCI_POSITIONFROMLINE, from);
		long end = sci(v, SCI_GETLINEENDPOSITION, to);
		sci(v, SCI_BEGINUNDOACTION);
		sci(v, SCI_SETTARGETRANGE, s, end);
		sci(v, SCI_REPLACETARGET, joined.size(), reinterpret_cast<sptr_t>(joined.data()));
		sci(v, SCI_ENDUNDOACTION);
	}

	// Applies a per-line transformation to the selected lines (or the document).
	void transformLines(ScintillaView* v, const std::function<void(std::vector<std::string>&)>& f)
	{
		long from, to;
		lineRange(v, from, to);
		auto lines = getLines(v, from, to);
		f(lines);
		replaceLines(v, from, to, lines);
	}

	// Case conversions on the selection (ScintillaEditView::convertSelectedTextTo).
	enum CaseConv { ProperForce, ProperBlend, SentenceForce, SentenceBlend, Invert, Random };

	void convertCase(ScintillaView* v, CaseConv mode)
	{
		long s = sci(v, SCI_GETSELECTIONSTART), e = sci(v, SCI_GETSELECTIONEND);
		if (s == e)
			return;
		std::wstring w = toW(range(v, s, e));
		static std::mt19937 rng{std::random_device{}()};
		bool newWord = true, newSentence = true, wasEndPunct = false;
		for (size_t i = 0; i < w.size(); ++i)
		{
			wchar_t c = w[i];
			bool alpha = iswalnum(c);
			switch (mode)
			{
				case ProperForce:
				case ProperBlend:
					if (alpha)
					{
						if (newWord)
							w[i] = towupper(c);
						else if (mode == ProperForce)
							w[i] = towlower(c);
					}
					newWord = !alpha && c != L'\'';
					break;
				case SentenceForce:
				case SentenceBlend:
					if (iswalpha(c))
					{
						if (newSentence)
						{
							w[i] = towupper(c);
							newSentence = false;
						}
						else if (mode == SentenceForce)
							w[i] = towlower(c);
					}
					if (c == L'.' || c == L'!' || c == L'?')
						wasEndPunct = true;
					else if (iswspace(c) && wasEndPunct)
					{
						newSentence = true;
						wasEndPunct = false;
					}
					else if (!iswspace(c))
						wasEndPunct = false;
					if (c == L'\r' || c == L'\n')
						newSentence = true;
					break;
				case Invert:
					w[i] = iswupper(c) ? towlower(c) : towupper(c);
					break;
				case Random:
					w[i] = (rng() & 1) ? towupper(c) : towlower(c);
					break;
			}
		}
		std::string out = toU8(w);
		sci(v, SCI_BEGINUNDOACTION);
		sci(v, SCI_SETTARGETRANGE, s, e);
		sci(v, SCI_REPLACETARGET, out.size(), reinterpret_cast<sptr_t>(out.data()));
		sci(v, SCI_SETSEL, s, s + out.size());
		sci(v, SCI_ENDUNDOACTION);
	}

	bool isBlank(const std::string& l)
	{
		return l.find_first_not_of(" \t") == std::string::npos;
	}

	std::string trimTrailing(const std::string& l)
	{
		size_t e = l.find_last_not_of(" \t");
		return e == std::string::npos ? "" : l.substr(0, e + 1);
	}

	std::string trimLeading(const std::string& l)
	{
		size_t b = l.find_first_not_of(" \t");
		return b == std::string::npos ? "" : l.substr(b);
	}

	// Tabs <-> spaces (ScintillaEditView::convertIndentation semantics, simplified to columns).
	std::string tabToSpace(const std::string& l, int tab)
	{
		std::string out;
		int col = 0;
		for (unsigned char c : l)
		{
			if (c == '\t')
			{
				int n = tab - (col % tab);
				out.append(n, ' ');
				col += n;
			}
			else
			{
				out += c;
				if ((c & 0xC0) != 0x80)
					++col;
			}
		}
		return out;
	}

	std::string spaceToTab(const std::string& l, int tab, bool leadingOnly)
	{
		std::string expanded = tabToSpace(l, tab);
		std::string out;
		size_t i = 0;
		int col = 0;
		while (i < expanded.size())
		{
			if (leadingOnly && expanded[i] != ' ')
			{
				out += expanded.substr(i);
				break;
			}
			// Gather a run of spaces up to the next tab stop.
			size_t j = i;
			while (j < expanded.size() && expanded[j] == ' ' && (col + (int)(j - i)) % tab != tab - 1)
				++j;
			if (j < expanded.size() && expanded[j] == ' ' && (col + (int)(j - i)) % tab == tab - 1 && j - i + 1 >= 2)
			{
				out += '\t';
				col += (int)(j - i + 1);
				i = j + 1;
				continue;
			}
			unsigned char c = expanded[i];
			out += c;
			if ((c & 0xC0) != 0x80)
				++col;
			++i;
		}
		return out;
	}
}

@interface NppMainWindow (EditOps)
@end

@implementation NppMainWindow (EditOps)

+ (void)registerEditOps:(std::unordered_map<int, NppCommandHandler>&)t
{
	// ---- Sorting (upstream Sorters.h) ----
	for (int id : {IDM_EDIT_SORTLINES_LEXICOGRAPHIC_ASCENDING, IDM_EDIT_SORTLINES_LEXICOGRAPHIC_DESCENDING,
	               IDM_EDIT_SORTLINES_LEXICO_CASE_INSENS_ASCENDING, IDM_EDIT_SORTLINES_LEXICO_CASE_INSENS_DESCENDING,
	               IDM_EDIT_SORTLINES_INTEGER_ASCENDING, IDM_EDIT_SORTLINES_INTEGER_DESCENDING,
	               IDM_EDIT_SORTLINES_DECIMALCOMMA_ASCENDING, IDM_EDIT_SORTLINES_DECIMALCOMMA_DESCENDING,
	               IDM_EDIT_SORTLINES_DECIMALDOT_ASCENDING, IDM_EDIT_SORTLINES_DECIMALDOT_DESCENDING,
	               IDM_EDIT_SORTLINES_REVERSE_ORDER, IDM_EDIT_SORTLINES_RANDOMLY,
	               IDM_EDIT_SORTLINES_LENGTH_ASCENDING, IDM_EDIT_SORTLINES_LENGTH_DESCENDING,
	               IDM_EDIT_SORTLINES_LOCALE_ASCENDING, IDM_EDIT_SORTLINES_LOCALE_DESCENDING})
	{
		t[id] = ^(NppMainWindow* w) {
			ScintillaView* v = w.editor;
			long from, to;
			size_t fromCol = 0, toCol = 0;
			if (sci(v, SCI_GETSELECTIONS) > 1 && sci(v, SCI_SELECTIONISRECTANGLE))
			{
				long a = sci(v, SCI_GETRECTANGULARSELECTIONANCHOR), c = sci(v, SCI_GETRECTANGULARSELECTIONCARET);
				long la = sci(v, SCI_LINEFROMPOSITION, a), lc = sci(v, SCI_LINEFROMPOSITION, c);
				from = std::min(la, lc);
				to = std::max(la, lc);
				size_t oa = a - sci(v, SCI_POSITIONFROMLINE, la), oc = c - sci(v, SCI_POSITIONFROMLINE, lc);
				fromCol = std::min(oa, oc);
				toCol = std::max(oa, oc);
			}
			else
			{
				long s = sci(v, SCI_GETSELECTIONSTART), e = sci(v, SCI_GETSELECTIONEND);
				lineRange(v, from, to);
				if (s != e && from == to)
					return; // a single selected line isn't sorted
			}
			auto u8 = getLines(v, from, to);
			std::vector<std::wstring> lines;
			for (const auto& l : u8)
				lines.push_back(toW(l));
			int cmd = id;
			if (id == IDM_EDIT_SORTLINES_LOCALE_ASCENDING || id == IDM_EDIT_SORTLINES_LOCALE_DESCENDING)
			{
				// Locale order: macOS localized comparison (upstream uses the Windows sort locale).
				NSMutableArray* a = [NSMutableArray array];
				for (const auto& l : u8)
					[a addObject: [NSString stringWithUTF8String: l.c_str()] ?: @""];
				[a sortUsingComparator: ^NSComparisonResult(NSString* x, NSString* y) {
					NSComparisonResult r = [x localizedStandardCompare: y];
					return id == IDM_EDIT_SORTLINES_LOCALE_DESCENDING ? (NSComparisonResult)-r : r;
				}];
				for (NSUInteger i = 0; i < a.count; ++i)
					u8[i] = [a[i] UTF8String];
				replaceLines(v, from, to, u8);
				return;
			}
			if (!nppSortLines(lines, cmd, fromCol, toCol))
			{
				NSBeep();
				return;
			}
			for (size_t i = 0; i < lines.size(); ++i)
				u8[i] = toU8(lines[i]);
			replaceLines(v, from, to, u8);
		};
	}

	// ---- Line operations ----
	t[IDM_EDIT_REMOVE_ANY_DUP_LINES] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::unordered_set<std::string> seen;
			std::vector<std::string> out;
			for (const auto& l : lines)
				if (seen.insert(l).second)
					out.push_back(l);
			lines = out;
		});
	};
	t[IDM_EDIT_REMOVE_CONSECUTIVE_DUP_LINES] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::vector<std::string> out;
			for (const auto& l : lines)
				if (out.empty() || out.back() != l)
					out.push_back(l);
			lines = out;
		});
	};
	t[IDM_EDIT_REMOVEEMPTYLINES] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::vector<std::string> out;
			for (const auto& l : lines)
				if (!l.empty())
					out.push_back(l);
			lines = out;
		});
	};
	t[IDM_EDIT_REMOVEEMPTYLINESWITHBLANK] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::vector<std::string> out;
			for (const auto& l : lines)
				if (!isBlank(l))
					out.push_back(l);
			lines = out;
		});
	};
	auto blankLine = ^(NppMainWindow* w, BOOL above) {
		ScintillaView* v = w.editor;
		long line = sci(v, SCI_LINEFROMPOSITION, sci(v, SCI_GETCURRENTPOS));
		std::string e = eol(v);
		sci(v, SCI_BEGINUNDOACTION);
		if (above)
		{
			long p = sci(v, SCI_POSITIONFROMLINE, line);
			sci(v, SCI_INSERTTEXT, p, reinterpret_cast<sptr_t>(e.c_str()));
			sci(v, SCI_GOTOPOS, p);
		}
		else
		{
			long p = sci(v, SCI_GETLINEENDPOSITION, line);
			sci(v, SCI_INSERTTEXT, p, reinterpret_cast<sptr_t>(e.c_str()));
			sci(v, SCI_GOTOPOS, p + e.size());
		}
		sci(v, SCI_ENDUNDOACTION);
	};
	t[IDM_EDIT_BLANKLINEABOVECURRENT] = ^(NppMainWindow* w) { blankLine(w, YES); };
	t[IDM_EDIT_BLANKLINEBELOWCURRENT] = ^(NppMainWindow* w) { blankLine(w, NO); };

	// ---- Blank operations ----
	t[IDM_EDIT_TRIMTRAILING] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) { for (auto& l : lines) l = trimTrailing(l); });
	};
	t[IDM_EDIT_TRIMLINEHEAD] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) { for (auto& l : lines) l = trimLeading(l); });
	};
	t[IDM_EDIT_TRIM_BOTH] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) { for (auto& l : lines) l = trimLeading(trimTrailing(l)); });
	};
	t[IDM_EDIT_EOL2WS] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::string j;
			for (size_t i = 0; i < lines.size(); ++i)
				j += (i ? " " : "") + lines[i];
			lines = {j};
		});
	};
	t[IDM_EDIT_TRIMALL] = ^(NppMainWindow* w) {
		transformLines(w.editor, [](std::vector<std::string>& lines) {
			std::string j;
			for (const auto& l : lines)
			{
				std::string t = trimLeading(trimTrailing(l));
				if (t.empty())
					continue;
				j += (j.empty() ? "" : " ") + t;
			}
			lines = {j};
		});
	};
	t[IDM_EDIT_TAB2SW] = ^(NppMainWindow* w) {
		int tab = (int)sci(w.editor, SCI_GETTABWIDTH);
		transformLines(w.editor, [tab](std::vector<std::string>& lines) { for (auto& l : lines) l = tabToSpace(l, tab); });
	};
	t[IDM_EDIT_SW2TAB_ALL] = ^(NppMainWindow* w) {
		int tab = (int)sci(w.editor, SCI_GETTABWIDTH);
		transformLines(w.editor, [tab](std::vector<std::string>& lines) { for (auto& l : lines) l = spaceToTab(l, tab, false); });
	};
	t[IDM_EDIT_SW2TAB_LEADING] = ^(NppMainWindow* w) {
		int tab = (int)sci(w.editor, SCI_GETTABWIDTH);
		transformLines(w.editor, [tab](std::vector<std::string>& lines) { for (auto& l : lines) l = spaceToTab(l, tab, true); });
	};

	// ---- Case ----
	t[IDM_EDIT_PROPERCASE_FORCE] = ^(NppMainWindow* w) { convertCase(w.editor, ProperForce); };
	t[IDM_EDIT_PROPERCASE_BLEND] = ^(NppMainWindow* w) { convertCase(w.editor, ProperBlend); };
	t[IDM_EDIT_SENTENCECASE_FORCE] = ^(NppMainWindow* w) { convertCase(w.editor, SentenceForce); };
	t[IDM_EDIT_SENTENCECASE_BLEND] = ^(NppMainWindow* w) { convertCase(w.editor, SentenceBlend); };
	t[IDM_EDIT_INVERTCASE] = ^(NppMainWindow* w) { convertCase(w.editor, Invert); };
	t[IDM_EDIT_RANDOMCASE] = ^(NppMainWindow* w) { convertCase(w.editor, Random); };

	// ---- Comments ----
	auto lineComment = ^(NppMainWindow* w, int mode) { // 0 toggle, 1 comment, 2 uncomment
		NppBuffer* b = w.currentBuffer;
		if (!b.lang || b.lang->commentLine.empty())
		{
			NSBeep();
			return;
		}
		ScintillaView* e = w.editor;
		const std::string cl = b.lang->commentLine;
		long startLine = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETSELECTIONSTART));
		long endLine = sci(e, SCI_LINEFROMPOSITION, sci(e, SCI_GETSELECTIONEND));
		if (endLine > startLine && sci(e, SCI_GETSELECTIONEND) == sci(e, SCI_POSITIONFROMLINE, endLine))
			--endLine;
		auto indentPos = [e](long l) { return (long)sci(e, SCI_GETLINEINDENTPOSITION, l); };
		auto has = [&](long l) {
			long p = indentPos(l);
			for (size_t i = 0; i < cl.size(); ++i)
				if (sci(e, SCI_GETCHARAT, p + i) != cl[i])
					return false;
			return true;
		};
		sci(e, SCI_BEGINUNDOACTION);
		for (long l = startLine; l <= endLine; ++l)
		{
			long p = indentPos(l);
			if (p == sci(e, SCI_GETLINEENDPOSITION, l) && mode != 1)
				continue;
			bool commented = has(l);
			bool uncomment = mode == 2 || (mode == 0 && commented);
			if (uncomment && commented)
			{
				long len = cl.size();
				if (sci(e, SCI_GETCHARAT, p + len) == ' ')
					++len;
				sci(e, SCI_DELETERANGE, p, len);
			}
			else if (!uncomment)
			{
				std::string token = cl + " ";
				sci(e, SCI_INSERTTEXT, p, reinterpret_cast<sptr_t>(token.c_str()));
			}
		}
		sci(e, SCI_ENDUNDOACTION);
	};
	t[IDM_EDIT_BLOCK_COMMENT_SET] = ^(NppMainWindow* w) { lineComment(w, 1); };
	t[IDM_EDIT_BLOCK_UNCOMMENT] = ^(NppMainWindow* w) { lineComment(w, 2); };
	auto streamComment = ^(NppMainWindow* w, BOOL add) {
		NppBuffer* b = w.currentBuffer;
		if (!b.lang || b.lang->commentStart.empty() || b.lang->commentEnd.empty())
		{
			NSBeep();
			return;
		}
		ScintillaView* e = w.editor;
		std::string cs = b.lang->commentStart, ce = b.lang->commentEnd;
		long s = sci(e, SCI_GETSELECTIONSTART), en = sci(e, SCI_GETSELECTIONEND);
		if (s == en)
		{
			long pos = sci(e, SCI_GETCURRENTPOS);
			s = sci(e, SCI_WORDSTARTPOSITION, pos, 1);
			en = sci(e, SCI_WORDENDPOSITION, pos, 1);
		}
		std::string text = range(e, s, en);
		sci(e, SCI_BEGINUNDOACTION);
		if (add)
		{
			std::string r = cs + " " + text + " " + ce;
			sci(e, SCI_SETTARGETRANGE, s, en);
			sci(e, SCI_REPLACETARGET, r.size(), reinterpret_cast<sptr_t>(r.data()));
			sci(e, SCI_SETSEL, s, s + r.size());
		}
		else
		{
			// Remove the nearest enclosing comment delimiters.
			std::string all = range(e, 0, sci(e, SCI_GETLENGTH));
			size_t open = all.rfind(cs, s);
			size_t close = all.find(ce, std::max<long>(en - (long)ce.size(), 0));
			if (open != std::string::npos && close != std::string::npos && open < close)
			{
				long cl = (long)ce.size(), ol = (long)cs.size();
				if (close > 0 && all[close - 1] == ' ') { --close; ++cl; }
				if (open + ol < all.size() && all[open + ol] == ' ') ++ol;
				sci(e, SCI_DELETERANGE, close, cl);
				sci(e, SCI_DELETERANGE, open, ol);
			}
			else
				NSBeep();
		}
		sci(e, SCI_ENDUNDOACTION);
	};
	t[IDM_EDIT_STREAM_COMMENT] = ^(NppMainWindow* w) { streamComment(w, YES); };
	t[IDM_EDIT_STREAM_UNCOMMENT] = ^(NppMainWindow* w) { streamComment(w, NO); };

	// ---- Selection ----
	t[IDM_EDIT_BEGINENDSELECT] = ^(NppMainWindow* w) { [w toggleBeginEndSelect: NO]; };
	t[IDM_EDIT_BEGINENDSELECT_COLUMNMODE] = ^(NppMainWindow* w) { [w toggleBeginEndSelect: YES]; };

	// Multi-select All / Next (SCI_MULTIPLESELECTADDEACH / ADDNEXT with search flags).
	struct MS { int id; int flags; bool all; };
	for (MS m : {MS{IDM_EDIT_MULTISELECTALL, 0, true}, MS{IDM_EDIT_MULTISELECTALLMATCHCASE, SCFIND_MATCHCASE, true},
	             MS{IDM_EDIT_MULTISELECTALLWHOLEWORD, SCFIND_WHOLEWORD, true},
	             MS{IDM_EDIT_MULTISELECTALLMATCHCASEWHOLEWORD, SCFIND_MATCHCASE | SCFIND_WHOLEWORD, true},
	             MS{IDM_EDIT_MULTISELECTNEXT, 0, false}, MS{IDM_EDIT_MULTISELECTNEXTMATCHCASE, SCFIND_MATCHCASE, false},
	             MS{IDM_EDIT_MULTISELECTNEXTWHOLEWORD, SCFIND_WHOLEWORD, false},
	             MS{IDM_EDIT_MULTISELECTNEXTMATCHCASEWHOLEWORD, SCFIND_MATCHCASE | SCFIND_WHOLEWORD, false}})
	{
		t[m.id] = ^(NppMainWindow* w) {
			ScintillaView* v = w.editor;
			if (sci(v, SCI_GETSELECTIONEMPTY))
			{
				long pos = sci(v, SCI_GETCURRENTPOS);
				sci(v, SCI_SETSEL, sci(v, SCI_WORDSTARTPOSITION, pos, 1), sci(v, SCI_WORDENDPOSITION, pos, 1));
				if (!m.all)
					return;
			}
			sci(v, SCI_SETSEARCHFLAGS, m.flags);
			sci(v, SCI_TARGETWHOLEDOCUMENT);
			sci(v, m.all ? SCI_MULTIPLESELECTADDEACH : SCI_MULTIPLESELECTADDNEXT);
		};
	}
	t[IDM_EDIT_MULTISELECTUNDO] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		long n = sci(v, SCI_GETSELECTIONS);
		if (n > 1)
			sci(v, SCI_DROPSELECTIONN, n - 1);
	};
	t[IDM_EDIT_MULTISELECTSSKIP] = ^(NppMainWindow* w) {
		ScintillaView* v = w.editor;
		long n = sci(v, SCI_GETSELECTIONS);
		sci(v, SCI_TARGETWHOLEDOCUMENT);
		sci(v, SCI_MULTIPLESELECTADDNEXT);
		if (n > 0 && sci(v, SCI_GETSELECTIONS) > n)
			sci(v, SCI_DROPSELECTIONN, n - 1);
	};

	// ---- On Selection ----
	t[IDM_EDIT_OPENSELECTEDFILETOEDIT] = ^(NppMainWindow* w) {
		NSString* p = [[w selectedTextOrWord: NO] stringByTrimmingCharactersInSet: NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (!p.isAbsolutePath && w.currentBuffer.path)
			p = [w.currentBuffer.path.stringByDeletingLastPathComponent stringByAppendingPathComponent: p];
		if ([NSFileManager.defaultManager fileExistsAtPath: p])
			[w openPaths: @[p]];
		else
			NSBeep();
	};
	t[IDM_EDIT_OPENSELECTEDFILEFOLDERINEXPLORER] = ^(NppMainWindow* w) {
		NSString* p = [[w selectedTextOrWord: NO] stringByTrimmingCharactersInSet: NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if ([NSFileManager.defaultManager fileExistsAtPath: p])
			[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs: @[[NSURL fileURLWithPath: p]]];
	};
	t[IDM_EDIT_SEARCHONINTERNET] = ^(NppMainWindow* w) {
		NSString* word = [w selectedTextOrWord: YES];
		if (!word.length)
			return;
		const NppSettings& s = NppSettings::instance();
		NSString* url;
		switch (s._searchEngineChoice)
		{
			case 0: url = [NSString stringWithUTF8String: s._searchEngineCustom.c_str()]; break;
			case 1: url = @"https://www.google.com/search?q=$(CURRENT_WORD)"; break;
			case 4: url = @"https://search.yahoo.com/search?q=$(CURRENT_WORD)"; break;
			case 5: url = @"https://stackoverflow.com/search?q=$(CURRENT_WORD)"; break;
			default: url = @"https://duckduckgo.com/?q=$(CURRENT_WORD)"; break;
		}
		NSString* q = [word stringByAddingPercentEncodingWithAllowedCharacters: NSCharacterSet.URLQueryAllowedCharacterSet];
		url = [url stringByReplacingOccurrencesOfString: @"$(CURRENT_WORD)" withString: q ?: @""];
		[NSWorkspace.sharedWorkspace openURL: [NSURL URLWithString: url]];
	};

	// ---- Read-only for all documents ----
	t[IDM_EDIT_SETREADONLYFORALLDOCS] = ^(NppMainWindow* w) {
		for (NppBuffer* b in w.buffers)
			b.readOnly = YES;
		sci(w.editor, SCI_SETREADONLY, 1);
		[w refreshTabs];
	};
	t[IDM_EDIT_CLEARREADONLYFORALLDOCS] = ^(NppMainWindow* w) {
		for (NppBuffer* b in w.buffers)
			b.readOnly = NO;
		sci(w.editor, SCI_SETREADONLY, w.currentBuffer.fileReadOnly);
		[w refreshTabs];
	};

	// ---- Insert date time (customized) ----
	t[IDM_EDIT_INSERT_DATETIME_CUSTOMIZED] = ^(NppMainWindow* w) {
		NSDateFormatter* f = [[NSDateFormatter alloc] init];
		// Notepad++ uses Windows date pictures (yyyy-MM-dd HH:mm:ss): close to ICU's.
		f.dateFormat = [NSString stringWithUTF8String: NppSettings::instance()._dateTimeFormat.c_str()];
		std::string s = [f stringFromDate: [NSDate date]].UTF8String;
		sci(w.editor, SCI_REPLACESEL, 0, reinterpret_cast<sptr_t>(s.c_str()));
	};
}

// Port of Notepad_plus Begin/End Select: first call marks the anchor, second selects.
- (void)toggleBeginEndSelect:(BOOL)column
{
	static long anchor = -1;
	ScintillaView* v = self.editor;
	long pos = sci(v, SCI_GETCURRENTPOS);
	if (anchor < 0)
	{
		anchor = pos;
		return;
	}
	if (column)
	{
		sci(v, SCI_SETRECTANGULARSELECTIONANCHOR, anchor);
		sci(v, SCI_SETRECTANGULARSELECTIONCARET, pos);
	}
	else
		sci(v, SCI_SETSEL, anchor, pos);
	anchor = -1;
}

@end
