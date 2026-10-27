#include "NppSearchEngine.h"

#include "NppUpstream.h"
#include "BoostRegexSearch.h"

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	intptr_t searchInTarget(ScintillaView* v, const std::string& text, size_t fromPos, size_t toPos)
	{
		sci(v, SCI_SETTARGETRANGE, fromPos, toPos);
		return sci(v, SCI_SEARCHINTARGET, text.size(), reinterpret_cast<sptr_t>(text.data()));
	}

	void appendUtf8(std::string& out, uint32_t cp)
	{
		if (cp < 0x80)
			out += static_cast<char>(cp);
		else if (cp < 0x800)
		{
			out += static_cast<char>(0xC0 | (cp >> 6));
			out += static_cast<char>(0x80 | (cp & 0x3F));
		}
		else if (cp < 0x10000)
		{
			out += static_cast<char>(0xE0 | (cp >> 12));
			out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
			out += static_cast<char>(0x80 | (cp & 0x3F));
		}
		else
		{
			out += static_cast<char>(0xF0 | (cp >> 18));
			out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
			out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
			out += static_cast<char>(0x80 | (cp & 0x3F));
		}
	}

	bool readBase(const std::string& str, size_t pos, int* value, int base, int size)
	{
		int temp = 0;
		*value = 0;
		char max = '0' + static_cast<char>(base) - 1;
		for (int i = 0; i < size; ++i)
		{
			char current = str[pos + i];
			if (current >= 'A')
			{
				current &= 0xdf;
				current -= ('A' - '0' - 10);
			}
			else if (current > '9')
				return false;

			if (current >= '0' && current <= max)
			{
				temp *= base;
				temp += (current - '0');
			}
			else
				return false;
		}
		*value = temp;
		return true;
	}

	std::string lineAt(ScintillaView* v, intptr_t lstart, intptr_t lend)
	{
		std::string tmp(lend - lstart + 1, '\0');
		Sci_TextRangeFull tr{{lstart, lend}, tmp.data()};
		sci(v, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
		tmp.resize(lend - lstart);
		return tmp;
	}
}

namespace Searching
{
	const char* noFoundPotentialReason = "The given occurrence cannot be found. You may have forgotten to check \"Wrap around\" (to ON), \"Match case\" (to OFF), or \"Match whole word only\" (to OFF).";
	const char* regexEmptyFoundReason = "The regular expression to search is formed in a way that the search can find empty string. Please make sure the search results are what you want.";

	std::string convertExtendedToString(const std::string& query)
	{
		std::string result;
		size_t length = query.size();
		size_t i = 0;
		while (i < length)
		{
			char current = query[i];
			size_t charLeft = length - i - 1;
			if (current == '\\' && charLeft)
			{
				++i;
				--charLeft;
				current = query[i];
				switch (current)
				{
					case 'r': result += '\r'; break;
					case 'n': result += '\n'; break;
					case '0': result += '\0'; break;
					case 't': result += '\t'; break;
					case '\\': result += '\\'; break;
					case 'b':
					case 'd':
					case 'o':
					case 'x':
					case 'u':
					{
						int size = 0, base = 0;
						if (current == 'b') { size = 8; base = 2; }
						else if (current == 'o') { size = 3; base = 8; }
						else if (current == 'd') { size = 3; base = 10; }
						else if (current == 'x') { size = 2; base = 16; }
						else if (current == 'u') { size = 4; base = 16; }

						int res = 0;
						if (charLeft >= static_cast<size_t>(size) && readBase(query, i + 1, &res, base, size))
						{
							appendUtf8(result, static_cast<uint32_t>(res));
							i += size;
							break;
						}
						[[fallthrough]];
					}
					default:
						result += '\\';
						result += current;
						break;
				}
			}
			else
			{
				result += query[i];
			}
			++i;
		}
		return result;
	}

	int buildSearchFlags(const FindOption& option)
	{
		return (option._isWholeWord ? SCFIND_WHOLEWORD : 0) |
		       (option._isMatchCase ? SCFIND_MATCHCASE : 0) |
		       (option._searchType == FindRegex ? SCFIND_REGEXP | SCFIND_POSIX : 0) |
		       ((option._searchType == FindRegex && option._dotMatchesNewline) ? SCFIND_REGEXP_DOTMATCHESNL : 0);
	}

	void displaySectionCentered(ScintillaView* v, intptr_t posStart, intptr_t posEnd, bool isDownwards)
	{
		sci(v, SCI_ENSUREVISIBLE, sci(v, SCI_LINEFROMPOSITION, posStart));
		sci(v, SCI_ENSUREVISIBLE, sci(v, SCI_LINEFROMPOSITION, posEnd));

		sci(v, SCI_SETVISIBLEPOLICY, CARET_JUMPS | CARET_EVEN);
		sci(v, SCI_ENSUREVISIBLEENFORCEPOLICY, sci(v, SCI_LINEFROMPOSITION, isDownwards ? posEnd : posStart));
		sci(v, SCI_GOTOPOS, isDownwards ? posEnd : posStart);
		sci(v, SCI_SETVISIBLEPOLICY, CARET_EVEN);
		sci(v, SCI_ENSUREVISIBLEENFORCEPOLICY, sci(v, SCI_LINEFROMPOSITION, isDownwards ? posEnd : posStart));

		sci(v, SCI_SCROLLRANGE, posStart, posEnd);

		if (posStart > 0)
		{
			posStart = sci(v, SCI_POSITIONBEFORE, posStart);
			posStart = sci(v, SCI_POSITIONAFTER, posStart);
		}
		if (posEnd > 0)
		{
			posEnd = sci(v, SCI_POSITIONBEFORE, posEnd);
			posEnd = sci(v, SCI_POSITIONAFTER, posEnd);
		}

		sci(v, SCI_GOTOPOS, posEnd);
		sci(v, SCI_SETANCHOR, posStart);
		sci(v, SCI_CHOOSECARETX);
	}

	std::string scopeInfo(const FindOption& opt)
	{
		if (opt._isInSelection)
			return "in selected text";
		if (opt._isWrapAround)
			return "in entire file";
		if (opt._whichDirection == DIR_UP)
			return "from start-of-file to caret";
		return "from caret to end-of-file";
	}
}

void SearchEngine::statusNotFound(const std::string& text, const std::string& reason)
{
	status("Find: Can't find the text \"" + text + "\"", FSNotFound, reason);
}

bool SearchEngine::processFindNext(ScintillaView* v, const std::string& txt2find, const FindOption& opt,
                                   FindStatus* oFindStatus, FindNextType findNextType, MatchPosition* pMatch)
{
	if (oFindStatus)
		*oFindStatus = FSFound;
	if (txt2find.empty())
		return false;

	sci(v, SCI_CALLTIPCANCEL);

	std::string pText = opt._searchType == FindExtended ? Searching::convertExtendedToString(txt2find) : txt2find;

	intptr_t docLength = sci(v, SCI_GETLENGTH);
	intptr_t selStart = sci(v, SCI_GETSELECTIONSTART);
	intptr_t selEnd = sci(v, SCI_GETSELECTIONEND);

	intptr_t startPosition = selEnd;
	intptr_t endPosition = docLength;

	if (opt._whichDirection == DIR_UP)
	{
		startPosition = selEnd - 1;
		endPosition = 0;
	}

	if (opt._incrementalType == FirstIncremental)
	{
		startPosition = selStart;
		endPosition = docLength;
		if (opt._whichDirection == DIR_UP)
		{
			startPosition = selEnd;
			endPosition = 0;
		}
	}
	else if (opt._incrementalType == NextIncremental)
	{
		startPosition = selStart + 1;
		endPosition = docLength;
		if (opt._whichDirection == DIR_UP)
		{
			startPosition = selEnd - 1;
			endPosition = 0;
		}
	}

	int flags = Searching::buildSearchFlags(opt);
	switch (findNextType)
	{
		case FINDNEXTTYPE_FINDNEXT:
			flags |= SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;
			break;
		case FINDNEXTTYPE_REPLACENEXT:
			flags |= SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;
			break;
		case FINDNEXTTYPE_FINDNEXTFORREPLACE:
			flags |= SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_EMPTYMATCH_ALLOWATSTART | SCFIND_REGEXP_SKIPCRLFASONE;
			break;
	}

	// Never allow a zero length match in the middle of a line end marker
	if (sci(v, SCI_GETCHARAT, startPosition - 1) == '\r' && sci(v, SCI_GETCHARAT, startPosition) == '\n')
		flags = (flags & ~SCFIND_REGEXP_EMPTYMATCH_MASK) | SCFIND_REGEXP_EMPTYMATCH_NONE;

	sci(v, SCI_SETSEARCHFLAGS, flags);

	intptr_t posFind = searchInTarget(v, pText, startPosition, endPosition);
	if (posFind == -1)
	{
		if (opt._isWrapAround)
		{
			if (opt._whichDirection == DIR_DOWN)
			{
				startPosition = 0;
				endPosition = docLength;
				if (oFindStatus)
					*oFindStatus = FSEndReached;
			}
			else
			{
				startPosition = docLength;
				endPosition = 0;
				if (oFindStatus)
					*oFindStatus = FSTopReached;
			}
			posFind = searchInTarget(v, pText, startPosition, endPosition);
		}

		if (posFind == -1)
		{
			if (oFindStatus)
				*oFindStatus = FSNotFound;
			if (opt._incrementalType == NotIncremental)
			{
				bool isTheMostLaxMode = opt._isWrapAround && !opt._isMatchCase && !opt._isWholeWord;
				statusNotFound(txt2find, isTheMostLaxMode ? "" : Searching::noFoundPotentialReason);
			}
			return false;
		}
	}
	else if (posFind == FIND_INVALID_REGULAR_EXPRESSION)
	{
		status("Find: Invalid Regular Expression", FSNotFound, "");
		return false;
	}

	intptr_t start = posFind;
	intptr_t end = sci(v, SCI_GETTARGETEND);

	status("", FSNoMessage);

	sci(v, SCI_STOPRECORD);
	Searching::displaySectionCentered(v, start, end, opt._whichDirection == DIR_DOWN);
	if (start == end)
		sci(v, SCI_CALLTIPSHOW, start, reinterpret_cast<sptr_t>("^ zero length match"));

	if (pMatch)
	{
		pMatch->start = start;
		pMatch->end = end;
	}
	return true;
}

bool SearchEngine::processReplace(ScintillaView* v, bool readOnly, const std::string& txt2find, const std::string& txt2replace,
                                  const FindOption& options, bool replaceStopsWithoutFindingNext)
{
	if (txt2find.empty())
		return false;

	if (readOnly)
	{
		status("Replace: Cannot replace text. The current document is read only.", FSNotFound);
		return false;
	}

	FindOption replaceOptions = options;
	replaceOptions._incrementalType = FirstIncremental;

	intptr_t curStart = sci(v, SCI_GETSELECTIONSTART);
	intptr_t curEnd = sci(v, SCI_GETSELECTIONEND);
	FindStatus st;
	bool moreMatches = processFindNext(v, txt2find, replaceOptions, &st, FINDNEXTTYPE_FINDNEXTFORREPLACE);

	if (moreMatches)
	{
		intptr_t nextStart = sci(v, SCI_GETSELECTIONSTART);
		intptr_t nextEnd = sci(v, SCI_GETSELECTIONEND);

		if (nextStart == curStart && nextEnd == curEnd)
		{
			intptr_t start = curStart;
			intptr_t replacedLen = 0;
			if (replaceOptions._searchType == FindRegex)
				replacedLen = sci(v, SCI_REPLACETARGETRE, static_cast<uptr_t>(-1), reinterpret_cast<sptr_t>(txt2replace.c_str()));
			else
			{
				std::string r = replaceOptions._searchType == FindExtended ? Searching::convertExtendedToString(txt2replace) : txt2replace;
				replacedLen = sci(v, SCI_REPLACETARGET, r.size(), reinterpret_cast<sptr_t>(r.data()));
			}
			sci(v, SCI_SETSEL, start + replacedLen, start + replacedLen);

			if (replaceStopsWithoutFindingNext)
			{
				status("Replace: 1 occurrence was replaced.", FSMessage);
			}
			else
			{
				moreMatches = processFindNext(v, txt2find, replaceOptions, &st, FINDNEXTTYPE_REPLACENEXT);
				if (st == FSEndReached)
					status("Replace: Reached document end, started from top.", FSEndReached);
				else if (st == FSTopReached)
					status("Replace: Reached document beginning, started from bottom.", FSTopReached);
				else if (moreMatches)
					status("Replace: 1 occurrence was replaced. The next occurrence found.", FSMessage);
				else
					status("Replace: 1 occurrence was replaced. No more occurrences were found.", FSMessage);
			}
		}
	}
	else
	{
		bool isTheMostLaxMode = options._isWrapAround && !options._isMatchCase && !options._isWholeWord;
		status("Replace: no occurrence was found " + Searching::scopeInfo(options), FSNotFound,
		       isTheMostLaxMode ? "" : Searching::noFoundPotentialReason);
	}
	return moreMatches;
}

int SearchEngine::processAll(ScintillaView* v, ProcessOperation op, FindOption& opt, bool isEntire,
                             const std::function<void(const FoundHit&)>& onHit, int colourStyleID,
                             std::vector<MatchPosition>* pMatches)
{
	// Turn off SCN_MODIFIED during bulk operations, as upstream does.
	sptr_t notifFlag = sci(v, SCI_GETMODEVENTMASK);
	sci(v, SCI_SETMODEVENTMASK, 0);

	intptr_t selStart = sci(v, SCI_GETSELECTIONSTART);
	intptr_t selEnd = sci(v, SCI_GETSELECTIONEND);
	intptr_t docLength = sci(v, SCI_GETLENGTH);

	intptr_t startPosition = 0;
	intptr_t endPosition = docLength;

	if (opt._whichDirection == DIR_UP)
	{
		startPosition = 0;
		endPosition = selEnd;
	}
	else
	{
		startPosition = selStart;
		endPosition = docLength;
	}

	if (op == ProcessCountAll && opt._isInSelection)
	{
		startPosition = selStart;
		endPosition = selEnd;
	}
	else if (opt._isWrapAround || isEntire)
	{
		startPosition = 0;
		endPosition = docLength;
	}

	if (opt._isInSelection && (op == ProcessMarkAll || ((op == ProcessReplaceAll || op == ProcessFindAll) && !isEntire)))
	{
		startPosition = selStart;
		endPosition = selEnd;
	}

	if (op == ProcessMarkAllExt && colourStyleID != -1)
	{
		startPosition = 0;
		endPosition = docLength;
	}

	int nbProcessed = processRange(v, op, opt._str2Search, opt._str4Replace, startPosition, endPosition, opt, onHit, colourStyleID, pMatches);

	sci(v, SCI_SETMODEVENTMASK, notifFlag);

	if (nbProcessed == FIND_INVALID_REGULAR_EXPRESSION)
		return FIND_INVALID_REGULAR_EXPRESSION;

	if (nbProcessed > 0 && op == ProcessReplaceAll && opt._isInSelection)
	{
		intptr_t newDocLength = sci(v, SCI_GETLENGTH);
		endPosition += newDocLength - docLength;
		sci(v, SCI_SETSELECTION, endPosition, startPosition);
		sci(v, SCI_SCROLLRANGE, startPosition, endPosition);
	}
	return nbProcessed;
}

int SearchEngine::processRange(ScintillaView* v, ProcessOperation op, const std::string& txt2find, const std::string& txt2replace,
                               intptr_t startRange, intptr_t endRange, FindOption& opt,
                               const std::function<void(const FoundHit&)>& onHit, int colourStyleID,
                               std::vector<MatchPosition>* pMatches)
{
	int nbProcessed = 0;
	if (startRange == endRange || txt2find.empty())
		return 0;

	std::string pTextFind = txt2find;
	std::string pTextReplace = txt2replace;
	if (opt._searchType == FindExtended)
	{
		pTextFind = Searching::convertExtendedToString(pTextFind);
		if (op == ProcessReplaceAll)
			pTextReplace = Searching::convertExtendedToString(pTextReplace);
	}

	bool isRegExp = opt._searchType == FindRegex;
	int flags = Searching::buildSearchFlags(opt) | SCFIND_REGEXP_SKIPCRLFASONE;
	if (op == ProcessReplaceAll || op == ProcessFindAll || op == ProcessCountAll || op == ProcessMarkAll)
		flags |= SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH;

	if (op == ProcessMarkAll && colourStyleID == -1 && opt._doPurge)
		clearMarks(v, opt);

	sci(v, SCI_SETSEARCHFLAGS, flags);

	intptr_t targetStart = 0;
	while (targetStart >= 0)
	{
		targetStart = searchInTarget(v, pTextFind, startRange, endRange);
		if (targetStart == -1)
			break;
		if (targetStart == FIND_INVALID_REGULAR_EXPRESSION)
			return FIND_INVALID_REGULAR_EXPRESSION;

		intptr_t targetEnd = sci(v, SCI_GETTARGETEND);
		if (targetEnd > endRange)
			break;

		if (pMatches)
			pMatches->push_back({targetStart, targetEnd});

		intptr_t foundTextLen = targetEnd - targetStart;
		intptr_t replaceDelta = 0;

		switch (op)
		{
			case ProcessFindAll:
			case ProcessFindInFinder:
			{
				FoundHit hit;
				hit.start = targetStart;
				hit.end = targetEnd;
				hit.totalLineNumber = sci(v, SCI_GETLINECOUNT);
				intptr_t lineNumber = sci(v, SCI_LINEFROMPOSITION, targetStart);
				intptr_t lend = sci(v, SCI_GETLINEENDPOSITION, lineNumber);
				intptr_t lstart = sci(v, SCI_POSITIONFROMLINE, lineNumber);
				if (lend - lstart > SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - 3)
					lend = lstart + SC_SEARCHRESULT_LINEBUFFERMAXLENGTH - 4;
				hit.lineNumber = lineNumber + 1;
				hit.lineText = lineAt(v, lstart, lend);
				hit.markStart = targetStart - lstart;
				hit.markEnd = targetEnd - lstart;
				if (onHit)
					onHit(hit);
				break;
			}

			case ProcessReplaceAll:
			{
				intptr_t replacedLength;
				if (isRegExp)
					replacedLength = sci(v, SCI_REPLACETARGETRE, static_cast<uptr_t>(-1), reinterpret_cast<sptr_t>(pTextReplace.c_str()));
				else
					replacedLength = sci(v, SCI_REPLACETARGET, pTextReplace.size(), reinterpret_cast<sptr_t>(pTextReplace.data()));
				replaceDelta = replacedLength - foundTextLen;
				break;
			}

			case ProcessMarkAll:
			{
				if (foundTextLen > 0)
				{
					sci(v, SCI_SETINDICATORCURRENT, SCE_UNIVERSAL_FOUND_STYLE);
					sci(v, SCI_INDICATORFILLRANGE, targetStart, foundTextLen);
				}
				else if (opt._searchType == FindRegex)
				{
					opt._regexEmptyStringFound = true;
				}

				if (opt._doMarkLine)
				{
					intptr_t lineNumber = sci(v, SCI_LINEFROMPOSITION, targetStart);
					intptr_t lineNumberEnd = foundTextLen > 0 ? sci(v, SCI_LINEFROMPOSITION, targetEnd - 1) : lineNumber;
					for (intptr_t i = lineNumber; i <= lineNumberEnd; ++i)
					{
						if (!(sci(v, SCI_MARKERGET, i) & (1 << MARK_BOOKMARK)))
							sci(v, SCI_MARKERADD, i, MARK_BOOKMARK);
					}
				}
				break;
			}

			case ProcessMarkAllExt:
				if (foundTextLen > 0)
				{
					sci(v, SCI_SETINDICATORCURRENT, colourStyleID);
					sci(v, SCI_INDICATORFILLRANGE, targetStart, foundTextLen);
				}
				break;

			case ProcessHighLightAll:
				if (foundTextLen > 0)
				{
					sci(v, SCI_SETINDICATORCURRENT, SCE_UNIVERSAL_FOUND_STYLE_SMART);
					sci(v, SCI_INDICATORFILLRANGE, targetStart, foundTextLen);
				}
				break;

			case ProcessMarkAll_IncSearch:
				if (foundTextLen > 0)
				{
					sci(v, SCI_SETINDICATORCURRENT, SCE_UNIVERSAL_FOUND_STYLE_INC);
					sci(v, SCI_INDICATORFILLRANGE, targetStart, foundTextLen);
				}
				break;

			case ProcessCountAll:
				if (foundTextLen == 0 && opt._searchType == FindRegex)
					opt._regexEmptyStringFound = true;
				break;
		}
		++nbProcessed;

		// Stop after the last occurrence, avoiding endless replacement of "$".
		if (targetStart + foundTextLen == endRange)
			break;

		startRange = targetStart + foundTextLen + replaceDelta;
		endRange += replaceDelta;
	}
	return nbProcessed;
}

void SearchEngine::clearMarks(ScintillaView* v, const FindOption& opt)
{
	if (opt._isInSelection)
	{
		intptr_t s = sci(v, SCI_GETSELECTIONSTART);
		intptr_t e = sci(v, SCI_GETSELECTIONEND);
		sci(v, SCI_SETINDICATORCURRENT, SCE_UNIVERSAL_FOUND_STYLE);
		sci(v, SCI_INDICATORCLEARRANGE, s, e - s);
		if (opt._doMarkLine)
		{
			intptr_t l1 = sci(v, SCI_LINEFROMPOSITION, s);
			intptr_t l2 = sci(v, SCI_LINEFROMPOSITION, e - 1);
			for (intptr_t l = l1; l <= l2; ++l)
				sci(v, SCI_MARKERDELETE, l, MARK_BOOKMARK);
		}
	}
	else
	{
		sci(v, SCI_SETINDICATORCURRENT, SCE_UNIVERSAL_FOUND_STYLE);
		sci(v, SCI_INDICATORCLEARRANGE, 0, sci(v, SCI_GETLENGTH));
		if (opt._doMarkLine)
			sci(v, SCI_MARKERDELETEALL, MARK_BOOKMARK);
	}
	status("", FSNoMessage);
}
