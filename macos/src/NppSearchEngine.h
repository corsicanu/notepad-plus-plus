// Search/replace core, ported from PowerEditor's FindReplaceDlg.cpp
// (Searching, processFindNext, processReplace, processAll, processRange).
// Text is UTF-8 throughout: every document lives in Scintilla as UTF-8.
#pragma once

#import "ScintillaView.h"

#include <functional>
#include <string>
#include <vector>

#define DIR_DOWN true
#define DIR_UP false
#define FIND_INVALID_REGULAR_EXPRESSION -2
#define FINDTEMPSTRING_MAXSIZE (1024 * 1024)

enum SearchIncrementalType { NotIncremental, FirstIncremental, NextIncremental };
enum SearchType { FindNormal, FindExtended, FindRegex };
enum ProcessOperation { ProcessFindAll, ProcessReplaceAll, ProcessCountAll, ProcessMarkAll, ProcessHighLightAll, ProcessMarkAll_IncSearch, ProcessMarkAllExt, ProcessFindInFinder };
enum FindNextType { FINDNEXTTYPE_FINDNEXT, FINDNEXTTYPE_REPLACENEXT, FINDNEXTTYPE_FINDNEXTFORREPLACE };
enum FindStatus { FSFound, FSNotFound, FSTopReached, FSEndReached, FSMessage, FSNoMessage };

struct FindOption
{
	bool _isWholeWord = true;
	bool _isMatchCase = true;
	bool _isWrapAround = true;
	bool _whichDirection = DIR_DOWN;
	SearchIncrementalType _incrementalType = NotIncremental;
	SearchType _searchType = FindNormal;
	bool _doPurge = false;
	bool _doMarkLine = false;
	bool _isInSelection = false;
	std::string _str2Search;
	std::string _str4Replace;
	std::string _filters;
	std::string _directory;
	bool _isRecursive = true;
	bool _isInHiddenDir = false;
	bool _dotMatchesNewline = false;
	bool _isMatchLineNumber = false;

	bool _regexEmptyStringFound = false;
};

struct MatchPosition
{
	intptr_t start = -1;
	intptr_t end = -1;
};

// One hit reported to the search results window.
struct FoundHit
{
	intptr_t start = 0;
	intptr_t end = 0;
	size_t lineNumber = 0;          // 1-based
	size_t totalLineNumber = 0;
	std::string lineText;           // line content, truncated like upstream
	intptr_t markStart = 0;         // match position inside lineText
	intptr_t markEnd = 0;
};

namespace Searching
{
	// "\n", "\t", "\x41", "€"... -> bytes. Port of convertExtendedToString, UTF-8 output.
	std::string convertExtendedToString(const std::string& query);

	int buildSearchFlags(const FindOption& option);

	void displaySectionCentered(ScintillaView* view, intptr_t posStart, intptr_t posEnd, bool isDownwards = true);

	// Status-bar scope suffix: "in entire file", "in selected text", ...
	std::string scopeInfo(const FindOption& opt);

	extern const char* noFoundPotentialReason;
	extern const char* regexEmptyFoundReason;
}

class SearchEngine
{
public:
	// Messages for the dialog's status line.
	std::function<void(const std::string& msg, FindStatus status, const std::string& tooltip)> setStatus;

	bool processFindNext(ScintillaView* view, const std::string& txt2find, const FindOption& opt,
	                     FindStatus* oFindStatus, FindNextType type = FINDNEXTTYPE_FINDNEXT, MatchPosition* pMatch = nullptr);

	bool processReplace(ScintillaView* view, bool readOnly, const std::string& txt2find, const std::string& txt2replace,
	                    const FindOption& opt, bool replaceStopsWithoutFindingNext);

	// Returns the number processed or FIND_INVALID_REGULAR_EXPRESSION. `onHit` receives Find All results.
	int processAll(ScintillaView* view, ProcessOperation op, FindOption& opt, bool isEntire,
	               const std::function<void(const FoundHit&)>& onHit = nullptr, int colourStyleID = -1,
	               std::vector<MatchPosition>* pMatches = nullptr);

	int processRange(ScintillaView* view, ProcessOperation op, const std::string& txt2find, const std::string& txt2replace,
	                 intptr_t startRange, intptr_t endRange, FindOption& opt,
	                 const std::function<void(const FoundHit&)>& onHit = nullptr, int colourStyleID = -1,
	                 std::vector<MatchPosition>* pMatches = nullptr);

	void clearMarks(ScintillaView* view, const FindOption& opt);

private:
	void statusNotFound(const std::string& text, const std::string& reason);
	void status(const std::string& msg, FindStatus s, const std::string& tip = "")
	{
		if (setStatus)
			setStatus(msg, s, tip);
	}
};
