// Application settings, named after the fields of PowerEditor's NppGUI /
// ScintillaViewParams so the mapping to config.xml stays obvious.
#pragma once

#include <string>
#include <vector>

struct NppSettings
{
	// Searching (NppGUI)
	bool _enableSmartHilite = true;
	bool _smartHiliteCaseSensitive = false;
	bool _smartHiliteWordOnly = true;
	bool _smartHiliteUseFindSettings = false;
	bool _smartHiliteOnAnotherView = false;
	bool _replaceStopsWithoutFindingNext = false;
	bool _fillFindFieldWithSelected = true;
	bool _fillFindFieldSelectCaret = true;
	bool _finderPurgeBeforeEverySearch = false;
	bool _finderLinesAreCurrentlyWrapped = false;
	bool _finderShowOnlyOneEntryPerFoundLine = true;
	bool _confirmReplaceInAllOpenDocs = true;
	bool _markAllCaseSensitive = false;
	bool _markAllWordOnly = true;
	bool _isSearchEngineCustom = false;
	int _inSelectionAutocheckThreshold = 1024;
	int _nbMaxFindHistoryPath = 10;
	int _nbMaxFindHistoryFilter = 10;
	int _nbMaxFindHistoryFind = 10;
	int _nbMaxFindHistoryReplace = 10;

	// Find history (FindHistory)
	std::vector<std::string> _findHistoryFinds;
	std::vector<std::string> _findHistoryReplaces;
	std::vector<std::string> _findHistoryFilters;
	std::vector<std::string> _findHistoryPaths;
	bool _isMatchWord = false;
	bool _isMatchCase = false;
	bool _isWrap = true;
	bool _isDirectionDown = true;
	bool _dotMatchesNewline = false;
	int _searchMode = 0; // 0 normal, 1 extended, 2 regex
	bool _isFifRecuisive = true;
	bool _isFifInHiddenFolder = false;
	bool _isFolderFollowDoc = false;
	bool _isBookmarkLine = false;
	bool _isPurge = false;
	bool _isIncrementalMatchCase = false;
	bool _isIncrementalHighlightAll = true;
	bool _isIncrementalCount = false;
	int _transparencyMode = 1; // 0 none, 1 on losing focus, 2 always
	int _transparency = 150;

	static NppSettings& instance()
	{
		static NppSettings s;
		return s;
	}
};
