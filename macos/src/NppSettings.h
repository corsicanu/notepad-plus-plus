// Application settings, named after the fields of PowerEditor's NppGUI /
// ScintillaViewParams so the mapping to config.xml stays obvious.
#pragma once

#include <string>
#include <vector>

struct NppSettings
{
	// New documents / loading (NppGUI::_newDocDefaultSettings, _detectEncoding)
	int _newDocFormat = 2;            // EolType: 0 Windows, 1 Mac (CR), 2 Unix. Notepad++ uses the OS default.
	int _newDocUnicodeMode = 4;       // UniMode: uniUTF8_NoBOM
	int _newDocLang = 0;              // LangType: L_TEXT
	bool _openAnsiAsUtf8 = true;
	bool _detectEncoding = true;

	// Editing (TabSetting, ScintillaPrimaryView, Caret)
	int _tabSize = 4;
	bool _tabReplaceBySpace = false;
	bool _backspaceUnindent = false;
	bool _lineNumberShow = true;
	bool _bookMarkMarginShow = true;
	bool _indentGuideLineShow = true;
	std::string _folderMarkStyle = "box";       // simple, arrow, circle, box, none
	int _isChangeHistoryEnabled = 1;            // 0 off, 1 margin, 2 indicators, 3 both
	int _currentLineIndicator = 1;              // 0 none, 1 background, 2 frame
	int _currentLineFrameWidth = 1;
	bool _wrap = false;
	std::string _lineWrapMethod = "aligned";    // default, aligned, indent
	bool _whiteSpaceShow = false;
	bool _eolShow = false;
	int _zoom = 0;
	bool _virtualSpace = false;
	bool _scrollBeyondLastLine = true;
	bool _multiSelection = true;
	bool _lineCopyCutWithoutSelection = true;
	int _caretWidth = 1;
	int _caretBlinkRate = 600;
	bool _statusBarShow = true;
	bool _toolbarShow = true;
	int _toolbarIconSet = 0;                    // NppToolbarIconSet

	// TabBar
	bool _tabDragAndDrop = true;
	bool _tabDrawTopBar = true;
	bool _tabDrawInactive = true;
	bool _tabReduce = true;
	bool _tabCloseButton = true;
	bool _tabDoubleClickClose = false;
	bool _tabPinButton = true;
	bool _tabBarHide = false;
	bool _tabQuitOnEmpty = false;

	// Files, session, backup
	int _fileAutoDetection = 0x02;              // cdEnabled4CurrentFile
	bool _rememberLastSession = true;
	int _backupAction = 0;                      // 0 none, 1 simple, 2 verbose
	bool _useCustomBackupDir = false;
	std::string _backupDir;
	bool _isSnapshotMode = true;
	int _snapshotBackupTiming = 7000;           // ms
	std::string _dateTimeFormat = "yyyy-MM-dd HH:mm:ss";
	bool _dateTimeReverseDefaultOrder = false;

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
