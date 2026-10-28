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

	// DarkMode (Notepad++: Light / Dark / Follow Windows -> Follow macOS)
	bool _darkModeEnable = false;
	bool _darkModeFollowOS = true;              // "enableWindowsMode"
	std::string _darkThemeName = "DarkModeDefault.xml";
	std::string _lightThemeName;                // empty = stylers.xml

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

	// ---- Preferences pages (bound in NppPreferences.mm, stored via NppSettingsRegistry) ----
	bool _menuBarHide = false;
	bool _hideMenuRightShortcuts = false;
	int _toolbarColor = -1;
	bool _tabVertical = false;
	bool _tabMultiLine = false;
	bool _tabAltIcons = false;
	bool _tabShowOnlyPinnedButton = false;
	bool _tabButtonsOnInactive = false;
	int _tabCompactLabelLen = 0;
	bool _smoothFont = false;
	bool _foldCmdToggable = false;
	bool _rightClickKeepsSelection = false;
	bool _selectedTextFgSingleColor = false;
	bool _disableAdvancedScrolling = false;
	bool _disableSelectedTextDragDrop = false;
	bool _columnSel2MultiEdit = true;
	int _borderWidth = 2;
	bool _borderEdge = true;
	bool _isEdgeBgMode = false;
	std::string _edgeMultiColumnPos;
	bool _lineNumberDynamicWidth = true;
	int _paddingLeft = 0;
	int _paddingRight = 0;
	int _distractionFreeDivPart = 4;
	bool _addNewDocOnStartup = false;
	bool _useContentAsTabName = false;
	int _openSaveDir = 0;                       // 0 follow current doc, 1 remember last, 2 always this dir
	std::string _defaultDirPath;
	std::string _lastUsedDirPath;
	bool _isFolderDroppedOpenFiles = false;
	bool _checkHistoryFiles = false;
	bool _langMenuCompact = true;
	bool _backSlashIsEscapeCharacterForSql = true;
	int _maintainIndent = 2;                    // 0 none, 1 basic, 2 advanced
	bool _enableTagsMatchHilite = true;
	bool _enableTagAttrsHilite = true;
	bool _enableHiliteNonHTMLZone = false;
	bool _findDlgAlwaysVisible = false;
	bool _monospacedFontFindDlg = false;
	bool _fillDirFieldFromActiveDoc = false;
	int _fillFindWhatThreshold = 1024;
	bool _fifIgnoreUnsavedChanges = false;
	bool _keepSessionAbsentFileEntries = false;
	int _autoCAction = 3;                       // 0 none, 1 function, 2 word, 3 both (auto-completion)
	int _autoCFromNbChar = 1;
	bool _autoCIgnoreNumbers = true;
	bool _autoCInsertWithEnter = true;
	bool _autoCInsertWithTab = true;
	bool _autoCBrief = false;
	bool _funcParams = true;
	bool _insertParentheses = false;
	bool _insertBrackets = false;
	bool _insertCurlyBrackets = false;
	bool _insertQuotes = false;
	bool _insertDoubleQuotes = false;
	bool _insertHtmlXmlTag = false;
	std::vector<std::pair<char, char>> _matchedPairs;   // <GUIConfig name="auto-insert"><UserDefinePair open close>
	int _multiInstSetting = 0;
	bool _wordCharUseDefault = true;
	std::string _wordCharsAdded;
	int _leftmostDelimiter = 40;
	int _rightmostDelimiter = 41;
	bool _delimiterSelectionOnEntireDocument = false;
	std::string _cloudPath;
	int _urlMode = 2;                           // 0 off, 1 underline, 2 no underline? (upstream URL value)
	std::string _uriCustomizedSchemes = "svn:// cvs:// git:// imap:// irc:// irc6:// ircs:// ldap:// ldaps:// news: telnet:// gopher:// ssh:// sftp:// smb:// skype: snmp:// spotify: steam:// sms: slack:// chrome:// bitcoin:";
	int _searchEngineChoice = 2;
	std::string _searchEngineCustom;
	bool _largeFileRestrictionEnabled = true;
	int _largeFileSizeMB = 200;
	bool _largeFileAllowAutoCompletion = false;
	bool _largeFileAllowBraceMatch = false;
	bool _largeFileAllowSmartHilite = false;
	bool _largeFileAllowClickableLink = false;
	bool _largeFileDeactivateWordWrap = true;
	bool _largeFileSuppress2GBWarning = false;
	bool _muteSounds = false;
	bool _shortTitlebar = false;
	bool _saveAllConfirm = true;
	bool _docPeekOnTab = false;
	bool _docPeekOnMap = false;
	std::string _sessionExt;
	std::string _workspaceExt;

	static NppSettings& instance()
	{
		static NppSettings s;
		return s;
	}
};
