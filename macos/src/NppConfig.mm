#import <Foundation/Foundation.h>

#include "NppConfig.h"
#include "NppSettings.h"
#include "NppUpstream.h"
#include "NppXml.h"
#include "LangManager.h"

#include <algorithm>
#include <cstring>

namespace
{
	pugi::xml_document g_doc;

	pugi::xml_node root(bool create)
	{
		pugi::xml_node r = g_doc.child("NotepadPlus");
		if (!r && create)
			r = g_doc.append_child("NotepadPlus");
		return r;
	}

	pugi::xml_node child(pugi::xml_node parent, const char* name, bool create)
	{
		pugi::xml_node n = parent.child(name);
		if (!n && create)
			n = parent.append_child(name);
		return n;
	}

	// <GUIConfigs><GUIConfig name="..."> ...
	pugi::xml_node gui(const char* name, bool create)
	{
		pugi::xml_node r = root(create);
		if (!r)
			return {};
		pugi::xml_node configs = child(r, "GUIConfigs", create);
		if (!configs)
			return {};
		for (pugi::xml_node n = configs.child("GUIConfig"); n; n = n.next_sibling("GUIConfig"))
			if (std::strcmp(n.attribute("name").as_string(), name) == 0)
				return n;
		if (!create)
			return {};
		pugi::xml_node n = configs.append_child("GUIConfig");
		n.append_attribute("name") = name;
		return n;
	}

	bool getBool(pugi::xml_node n, const char* attr, bool def)
	{
		pugi::xml_attribute a = n.attribute(attr);
		if (!a)
			return def;
		return std::strcmp(a.as_string(), "yes") == 0 || std::strcmp(a.as_string(), "1") == 0 || std::strcmp(a.as_string(), "show") == 0;
	}

	void setAttr(pugi::xml_node n, const char* attr, const char* v)
	{
		pugi::xml_attribute a = n.attribute(attr);
		if (!a)
			a = n.append_attribute(attr);
		a = v;
	}

	void setAttr(pugi::xml_node n, const char* attr, long v)
	{
		setAttr(n, attr, std::to_string(v).c_str());
	}

	void setBool(pugi::xml_node n, const char* attr, bool v, const char* yes = "yes", const char* no = "no")
	{
		setAttr(n, attr, v ? yes : no);
	}

	int getInt(pugi::xml_node n, const char* attr, int def)
	{
		pugi::xml_attribute a = n.attribute(attr);
		return a ? a.as_int(def) : def;
	}

	std::string text(pugi::xml_node n)
	{
		return n ? n.text().as_string() : "";
	}

	void setText(pugi::xml_node n, const char* v)
	{
		n.text().set(v);
	}

	std::vector<std::string> readList(pugi::xml_node parent, const char* name)
	{
		std::vector<std::string> v;
		for (pugi::xml_node n = parent.child(name); n; n = n.next_sibling(name))
			v.push_back(n.attribute("name").as_string());
		return v;
	}

	void writeList(pugi::xml_node parent, const char* name, const std::vector<std::string>& v)
	{
		while (pugi::xml_node n = parent.child(name))
			parent.remove_child(n);
		for (const auto& s : v)
			parent.append_child(name).append_attribute("name") = s.c_str();
	}

	int detectionFromString(const std::string& v)
	{
		if (v == "yesOld") return cdEnabled4AllFiles;
		if (v == "autoOld") return cdEnabled4AllFiles | cdAutoUpdate;
		if (v == "Update2EndOld") return cdEnabled4AllFiles | cdGo2end;
		if (v == "autoUpdate2EndOld") return cdEnabled4AllFiles | cdAutoUpdate | cdGo2end;
		if (v == "yes") return cdEnabled4CurrentFile;
		if (v == "auto") return cdEnabled4CurrentFile | cdAutoUpdate;
		if (v == "Update2End") return cdEnabled4CurrentFile | cdGo2end;
		if (v == "autoUpdate2End") return cdEnabled4CurrentFile | cdAutoUpdate | cdGo2end;
		return cdDisabled;
	}

	const char* detectionToString(int d)
	{
		bool all = d & cdEnabled4AllFiles;
		bool cur = d & cdEnabled4CurrentFile;
		bool upd = d & cdAutoUpdate;
		bool end = d & cdGo2end;
		if (!all && !cur)
			return "no";
		if (all)
			return upd ? (end ? "autoUpdate2EndOld" : "autoOld") : (end ? "Update2EndOld" : "yesOld");
		return upd ? (end ? "autoUpdate2End" : "auto") : (end ? "Update2End" : "yes");
	}
}

NppConfig& NppConfig::instance()
{
	static NppConfig c;
	return c;
}

NppConfig::NppConfig()
{
	NSString* dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
	                 stringByAppendingPathComponent: @"Notepad++"];
	[NSFileManager.defaultManager createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
	_dir = dir.fileSystemRepresentation;
}

void NppConfig::load()
{
	g_doc.reset();
	g_doc.load_file((_dir + "/config.xml").c_str());
	NppSettings& s = NppSettings::instance();
	pugi::xml_node r = root(false);
	if (!r)
		return;

	// Recent files
	if (pugi::xml_node h = r.child("History"))
	{
		nbMaxRecentFiles = getInt(h, "nbMaxFile", nbMaxRecentFiles);
		recentFiles.clear();
		for (pugi::xml_node f = h.child("File"); f; f = f.next_sibling("File"))
			recentFiles.push_back(f.attribute("filename").as_string());
	}

	// Find dialog state
	if (pugi::xml_node f = r.child("FindHistory"))
	{
		s._nbMaxFindHistoryPath = getInt(f, "nbMaxFindHistoryPath", s._nbMaxFindHistoryPath);
		s._nbMaxFindHistoryFilter = getInt(f, "nbMaxFindHistoryFilter", s._nbMaxFindHistoryFilter);
		s._nbMaxFindHistoryFind = getInt(f, "nbMaxFindHistoryFind", s._nbMaxFindHistoryFind);
		s._nbMaxFindHistoryReplace = getInt(f, "nbMaxFindHistoryReplace", s._nbMaxFindHistoryReplace);
		s._isMatchWord = getBool(f, "matchWord", s._isMatchWord);
		s._isMatchCase = getBool(f, "matchCase", s._isMatchCase);
		s._isWrap = getBool(f, "wrap", s._isWrap);
		s._isDirectionDown = getBool(f, "directionDown", s._isDirectionDown);
		s._isFifRecuisive = getBool(f, "fifRecuisive", s._isFifRecuisive);
		s._isFifInHiddenFolder = getBool(f, "fifInHiddenFolder", s._isFifInHiddenFolder);
		s._isFolderFollowDoc = getBool(f, "fifFolderFollowsDoc", s._isFolderFollowDoc);
		s._searchMode = getInt(f, "searchMode", s._searchMode);
		s._transparencyMode = getInt(f, "transparencyMode", s._transparencyMode);
		s._transparency = getInt(f, "transparency", s._transparency);
		s._dotMatchesNewline = getBool(f, "dotMatchesNewline", s._dotMatchesNewline);
		s._isBookmarkLine = getBool(f, "bookmarkLine", s._isBookmarkLine);
		s._isPurge = getBool(f, "purge", s._isPurge);
		s._isIncrementalMatchCase = getBool(f, "incrementalMatchCase", s._isIncrementalMatchCase);
		s._isIncrementalHighlightAll = getBool(f, "incrementalHighlightAll", s._isIncrementalHighlightAll);
		s._isIncrementalCount = getBool(f, "incrementalCount", s._isIncrementalCount);
		s._findHistoryPaths = readList(f, "Path");
		s._findHistoryFilters = readList(f, "Filter");
		s._findHistoryFinds = readList(f, "Find");
		s._findHistoryReplaces = readList(f, "Replace");
	}

	if (pugi::xml_node n = gui("AppPosition", false))
	{
		appX = getInt(n, "x", appX);
		appY = getInt(n, "y", appY);
		appW = getInt(n, "width", appW);
		appH = getInt(n, "height", appH);
		appMaximized = getBool(n, "isMaximized", false);
		appPositionValid = true;
	}
	if (pugi::xml_node n = gui("TabSetting", false))
	{
		s._tabSize = getInt(n, "size", s._tabSize);
		s._tabReplaceBySpace = getBool(n, "replaceBySpace", s._tabReplaceBySpace);
		s._backspaceUnindent = getBool(n, "backspaceUnindent", s._backspaceUnindent);
	}
	if (pugi::xml_node n = gui("ScintillaPrimaryView", false))
	{
		s._lineNumberShow = getBool(n, "lineNumberMargin", s._lineNumberShow);
		s._bookMarkMarginShow = getBool(n, "bookMarkMargin", s._bookMarkMarginShow);
		s._indentGuideLineShow = getBool(n, "indentGuideLine", s._indentGuideLineShow);
		if (const char* fs = n.attribute("folderMarkStyle").as_string(nullptr))
			s._folderMarkStyle = fs;
		s._isChangeHistoryEnabled = getInt(n, "isChangeHistoryEnabled", s._isChangeHistoryEnabled);
		s._currentLineIndicator = getInt(n, "currentLineIndicator", s._currentLineIndicator);
		s._currentLineFrameWidth = getInt(n, "currentLineFrameWidth", s._currentLineFrameWidth);
		s._wrap = getBool(n, "Wrap", s._wrap);
		s._whiteSpaceShow = getBool(n, "whiteSpaceShow", s._whiteSpaceShow);
		s._eolShow = getBool(n, "eolShow", s._eolShow);
		s._zoom = getInt(n, "zoom", s._zoom);
		s._virtualSpace = getBool(n, "virtualSpace", s._virtualSpace);
		s._scrollBeyondLastLine = getBool(n, "scrollBeyondLastLine", s._scrollBeyondLastLine);
		s._multiSelection = getBool(n, "multiSelection", s._multiSelection);
		s._lineCopyCutWithoutSelection = getBool(n, "lineCopyCutWithoutSelection", s._lineCopyCutWithoutSelection);
		if (const char* lw = n.attribute("lineWrapMethod").as_string(nullptr))
			s._lineWrapMethod = lw;
	}
	if (pugi::xml_node n = gui("NewDocDefaultSettings", false))
	{
		s._newDocFormat = getInt(n, "format", s._newDocFormat);
		s._newDocUnicodeMode = getInt(n, "encoding", s._newDocUnicodeMode);
		s._newDocLang = getInt(n, "lang", s._newDocLang);
		s._openAnsiAsUtf8 = getBool(n, "openAnsiAsUTF8", s._openAnsiAsUtf8);
	}
	if (pugi::xml_node n = gui("DetectEncoding", false))
		s._detectEncoding = text(n) == "yes";
	if (pugi::xml_node n = gui("Auto-detection", false))
		s._fileAutoDetection = detectionFromString(text(n));
	if (pugi::xml_node n = gui("RememberLastSession", false))
		s._rememberLastSession = text(n) == "yes";
	if (pugi::xml_node n = gui("Backup", false))
	{
		s._backupAction = getInt(n, "action", s._backupAction);
		s._useCustomBackupDir = getBool(n, "useCustumDir", s._useCustomBackupDir);
		s._backupDir = n.attribute("dir").as_string();
		s._isSnapshotMode = getBool(n, "isSnapshotMode", s._isSnapshotMode);
		s._snapshotBackupTiming = getInt(n, "snapshotBackupTiming", s._snapshotBackupTiming);
	}
	if (pugi::xml_node n = gui("SmartHighLight", false))
	{
		s._enableSmartHilite = text(n) == "yes";
		s._smartHiliteCaseSensitive = getBool(n, "matchCase", s._smartHiliteCaseSensitive);
		s._smartHiliteWordOnly = getBool(n, "wholeWordOnly", s._smartHiliteWordOnly);
		s._smartHiliteUseFindSettings = getBool(n, "useFindSettings", s._smartHiliteUseFindSettings);
		s._smartHiliteOnAnotherView = getBool(n, "onAnotherView", s._smartHiliteOnAnotherView);
	}
	if (pugi::xml_node n = gui("MarkAll", false))
	{
		s._markAllCaseSensitive = getBool(n, "matchCase", s._markAllCaseSensitive);
		s._markAllWordOnly = getBool(n, "wholeWordOnly", s._markAllWordOnly);
	}
	if (pugi::xml_node n = gui("Searching", false))
	{
		s._fillFindFieldWithSelected = getBool(n, "fillFindFieldWithSelected", s._fillFindFieldWithSelected);
		s._fillFindFieldSelectCaret = getBool(n, "fillFindFieldSelectCaret", s._fillFindFieldSelectCaret);
		s._replaceStopsWithoutFindingNext = getBool(n, "replaceStopsWithoutFindingNext", s._replaceStopsWithoutFindingNext);
		s._inSelectionAutocheckThreshold = getInt(n, "inSelectionAutocheckThreshold", s._inSelectionAutocheckThreshold);
		s._confirmReplaceInAllOpenDocs = getBool(n, "confirmReplaceInAllOpenDocs", s._confirmReplaceInAllOpenDocs);
	}
	if (pugi::xml_node n = gui("FinderConfig", false))
	{
		s._finderLinesAreCurrentlyWrapped = getBool(n, "wrappedLines", s._finderLinesAreCurrentlyWrapped);
		s._finderPurgeBeforeEverySearch = getBool(n, "purgeBeforeEverySearch", s._finderPurgeBeforeEverySearch);
		s._finderShowOnlyOneEntryPerFoundLine = getBool(n, "showOnlyOneEntryPerFoundLine", s._finderShowOnlyOneEntryPerFoundLine);
	}
	if (pugi::xml_node n = gui("Caret", false))
	{
		s._caretWidth = getInt(n, "width", s._caretWidth);
		s._caretBlinkRate = getInt(n, "blinkRate", s._caretBlinkRate);
	}
	if (pugi::xml_node n = gui("insertDateTime", false))
	{
		s._dateTimeFormat = n.attribute("customizedFormat").as_string(s._dateTimeFormat.c_str());
		s._dateTimeReverseDefaultOrder = getBool(n, "reverseDefaultOrder", s._dateTimeReverseDefaultOrder);
	}
	if (pugi::xml_node n = gui("StatusBar", false))
		s._statusBarShow = text(n) != "hide";
	if (pugi::xml_node n = gui("DarkMode", false))
	{
		s._darkModeEnable = getBool(n, "enable", s._darkModeEnable);
		s._darkModeFollowOS = getBool(n, "enableWindowsMode", s._darkModeFollowOS);
		s._darkThemeName = n.attribute("darkThemeName").as_string(s._darkThemeName.c_str());
		s._lightThemeName = n.attribute("lightThemeName").as_string(s._lightThemeName.c_str());
	}
	if (pugi::xml_node n = gui("globalOverride", false))
	{
		GlobalOverride& go = LangManager::instance().globalOverride;
		go.enableFg = getBool(n, "fg", false);
		go.enableBg = getBool(n, "bg", false);
		go.enableFont = getBool(n, "font", false);
		go.enableFontSize = getBool(n, "fontSize", false);
		go.enableBold = getBool(n, "bold", false);
		go.enableItalic = getBool(n, "italic", false);
		go.enableUnderLine = getBool(n, "underline", false);
	}
	if (pugi::xml_node n = gui("ToolBar", false))
	{
		s._toolbarShow = getBool(n, "visible", s._toolbarShow);
		std::string t = text(n);
		s._toolbarIconSet = t == "large" ? 1 : t == "small2" ? 2 : t == "large2" ? 3 : t == "standard" ? 4 : 0;
	}
	if (pugi::xml_node n = gui("TabBar", false))
	{
		s._tabDragAndDrop = getBool(n, "dragAndDrop", s._tabDragAndDrop);
		s._tabDrawTopBar = getBool(n, "drawTopBar", s._tabDrawTopBar);
		s._tabDrawInactive = getBool(n, "drawInactiveTab", s._tabDrawInactive);
		s._tabReduce = getBool(n, "reduce", s._tabReduce);
		s._tabCloseButton = getBool(n, "closeButton", s._tabCloseButton);
		s._tabDoubleClickClose = getBool(n, "doubleClick2Close", s._tabDoubleClickClose);
		s._tabPinButton = getBool(n, "pinButton", s._tabPinButton);
		s._tabBarHide = getBool(n, "hide", s._tabBarHide);
		s._tabQuitOnEmpty = getBool(n, "quitOnEmpty", s._tabQuitOnEmpty);
	}
}

void NppConfig::save()
{
	const NppSettings& s = NppSettings::instance();
	pugi::xml_node r = root(true);

	pugi::xml_node h = child(r, "History", true);
	setAttr(h, "nbMaxFile", nbMaxRecentFiles);
	while (pugi::xml_node f = h.child("File"))
		h.remove_child(f);
	for (const auto& f : recentFiles)
		h.append_child("File").append_attribute("filename") = f.c_str();

	pugi::xml_node f = child(r, "FindHistory", true);
	setAttr(f, "nbMaxFindHistoryPath", s._nbMaxFindHistoryPath);
	setAttr(f, "nbMaxFindHistoryFilter", s._nbMaxFindHistoryFilter);
	setAttr(f, "nbMaxFindHistoryFind", s._nbMaxFindHistoryFind);
	setAttr(f, "nbMaxFindHistoryReplace", s._nbMaxFindHistoryReplace);
	setBool(f, "matchWord", s._isMatchWord);
	setBool(f, "matchCase", s._isMatchCase);
	setBool(f, "wrap", s._isWrap);
	setBool(f, "directionDown", s._isDirectionDown);
	setBool(f, "fifRecuisive", s._isFifRecuisive);
	setBool(f, "fifInHiddenFolder", s._isFifInHiddenFolder);
	setBool(f, "fifFolderFollowsDoc", s._isFolderFollowDoc);
	setAttr(f, "searchMode", s._searchMode);
	setAttr(f, "transparencyMode", s._transparencyMode);
	setAttr(f, "transparency", s._transparency);
	setBool(f, "dotMatchesNewline", s._dotMatchesNewline);
	setBool(f, "bookmarkLine", s._isBookmarkLine);
	setBool(f, "purge", s._isPurge);
	setBool(f, "incrementalMatchCase", s._isIncrementalMatchCase);
	setBool(f, "incrementalHighlightAll", s._isIncrementalHighlightAll);
	setBool(f, "incrementalCount", s._isIncrementalCount);
	writeList(f, "Path", s._findHistoryPaths);
	writeList(f, "Filter", s._findHistoryFilters);
	writeList(f, "Find", s._findHistoryFinds);
	writeList(f, "Replace", s._findHistoryReplaces);

	pugi::xml_node n = gui("AppPosition", true);
	setAttr(n, "x", appX);
	setAttr(n, "y", appY);
	setAttr(n, "width", appW);
	setAttr(n, "height", appH);
	setBool(n, "isMaximized", appMaximized);

	n = gui("TabSetting", true);
	setBool(n, "replaceBySpace", s._tabReplaceBySpace);
	setAttr(n, "size", s._tabSize);
	setBool(n, "backspaceUnindent", s._backspaceUnindent);

	n = gui("ScintillaPrimaryView", true);
	setBool(n, "lineNumberMargin", s._lineNumberShow, "show", "hide");
	setBool(n, "bookMarkMargin", s._bookMarkMarginShow, "show", "hide");
	setBool(n, "indentGuideLine", s._indentGuideLineShow, "show", "hide");
	setAttr(n, "folderMarkStyle", s._folderMarkStyle.c_str());
	setAttr(n, "isChangeHistoryEnabled", s._isChangeHistoryEnabled);
	setAttr(n, "currentLineIndicator", s._currentLineIndicator);
	setAttr(n, "currentLineFrameWidth", s._currentLineFrameWidth);
	setBool(n, "Wrap", s._wrap);
	setBool(n, "whiteSpaceShow", s._whiteSpaceShow, "show", "hide");
	setBool(n, "eolShow", s._eolShow, "show", "hide");
	setAttr(n, "zoom", s._zoom);
	setBool(n, "virtualSpace", s._virtualSpace);
	setBool(n, "scrollBeyondLastLine", s._scrollBeyondLastLine);
	setBool(n, "multiSelection", s._multiSelection);
	setBool(n, "lineCopyCutWithoutSelection", s._lineCopyCutWithoutSelection);
	setAttr(n, "lineWrapMethod", s._lineWrapMethod.c_str());

	n = gui("NewDocDefaultSettings", true);
	setAttr(n, "format", s._newDocFormat);
	setAttr(n, "encoding", s._newDocUnicodeMode);
	setAttr(n, "lang", s._newDocLang);
	setBool(n, "openAnsiAsUTF8", s._openAnsiAsUtf8);

	setText(gui("DetectEncoding", true), s._detectEncoding ? "yes" : "no");
	setText(gui("Auto-detection", true), detectionToString(s._fileAutoDetection));
	setText(gui("RememberLastSession", true), s._rememberLastSession ? "yes" : "no");

	n = gui("Backup", true);
	setAttr(n, "action", s._backupAction);
	setBool(n, "useCustumDir", s._useCustomBackupDir);
	setAttr(n, "dir", s._backupDir.c_str());
	setBool(n, "isSnapshotMode", s._isSnapshotMode);
	setAttr(n, "snapshotBackupTiming", s._snapshotBackupTiming);

	n = gui("SmartHighLight", true);
	setText(n, s._enableSmartHilite ? "yes" : "no");
	setBool(n, "matchCase", s._smartHiliteCaseSensitive);
	setBool(n, "wholeWordOnly", s._smartHiliteWordOnly);
	setBool(n, "useFindSettings", s._smartHiliteUseFindSettings);
	setBool(n, "onAnotherView", s._smartHiliteOnAnotherView);

	n = gui("MarkAll", true);
	setBool(n, "matchCase", s._markAllCaseSensitive);
	setBool(n, "wholeWordOnly", s._markAllWordOnly);

	n = gui("Searching", true);
	setBool(n, "fillFindFieldWithSelected", s._fillFindFieldWithSelected);
	setBool(n, "fillFindFieldSelectCaret", s._fillFindFieldSelectCaret);
	setBool(n, "replaceStopsWithoutFindingNext", s._replaceStopsWithoutFindingNext);
	setAttr(n, "inSelectionAutocheckThreshold", s._inSelectionAutocheckThreshold);
	setBool(n, "confirmReplaceInAllOpenDocs", s._confirmReplaceInAllOpenDocs);

	n = gui("FinderConfig", true);
	setBool(n, "wrappedLines", s._finderLinesAreCurrentlyWrapped);
	setBool(n, "purgeBeforeEverySearch", s._finderPurgeBeforeEverySearch);
	setBool(n, "showOnlyOneEntryPerFoundLine", s._finderShowOnlyOneEntryPerFoundLine);

	n = gui("Caret", true);
	setAttr(n, "width", s._caretWidth);
	setAttr(n, "blinkRate", s._caretBlinkRate);

	n = gui("insertDateTime", true);
	setAttr(n, "customizedFormat", s._dateTimeFormat.c_str());
	setBool(n, "reverseDefaultOrder", s._dateTimeReverseDefaultOrder);

	setText(gui("StatusBar", true), s._statusBarShow ? "show" : "hide");

	n = gui("DarkMode", true);
	setBool(n, "enable", s._darkModeEnable);
	setBool(n, "enableWindowsMode", s._darkModeFollowOS);
	setAttr(n, "darkThemeName", s._darkThemeName.c_str());
	setAttr(n, "lightThemeName", s._lightThemeName.c_str());

	const GlobalOverride& go = LangManager::instance().globalOverride;
	n = gui("globalOverride", true);
	setBool(n, "fg", go.enableFg);
	setBool(n, "bg", go.enableBg);
	setBool(n, "font", go.enableFont);
	setBool(n, "fontSize", go.enableFontSize);
	setBool(n, "bold", go.enableBold);
	setBool(n, "italic", go.enableItalic);
	setBool(n, "underline", go.enableUnderLine);

	n = gui("ToolBar", true);
	setBool(n, "visible", s._toolbarShow);
	static const char* sets[] = {"small", "large", "small2", "large2", "standard"};
	setText(n, sets[std::max(0, std::min(4, s._toolbarIconSet))]);

	n = gui("TabBar", true);
	setBool(n, "dragAndDrop", s._tabDragAndDrop);
	setBool(n, "drawTopBar", s._tabDrawTopBar);
	setBool(n, "drawInactiveTab", s._tabDrawInactive);
	setBool(n, "reduce", s._tabReduce);
	setBool(n, "closeButton", s._tabCloseButton);
	setBool(n, "doubleClick2Close", s._tabDoubleClickClose);
	setBool(n, "pinButton", s._tabPinButton);
	setBool(n, "hide", s._tabBarHide);
	setBool(n, "quitOnEmpty", s._tabQuitOnEmpty);

	if (g_doc.first_child().type() != pugi::node_declaration)
	{
		pugi::xml_node decl = g_doc.prepend_child(pugi::node_declaration);
		decl.append_attribute("version") = "1.0";
		decl.append_attribute("encoding") = "UTF-8";
	}
	g_doc.save_file((_dir + "/config.xml").c_str(), "    ");
}

// ---- session.xml ---------------------------------------------------------

bool NppConfig::loadSession(const std::string& path, Session& session)
{
	pugi::xml_document doc;
	if (!doc.load_file(path.c_str()))
		return false;
	pugi::xml_node s = doc.child("NotepadPlus").child("Session");
	if (!s)
		return false;
	session.activeView = s.attribute("activeView").as_int(0);
	auto readView = [](pugi::xml_node view, std::vector<SessionFileInfo>& files, int& active) {
		active = view.attribute("activeIndex").as_int(0);
		for (pugi::xml_node f = view.child("File"); f; f = f.next_sibling("File"))
		{
			SessionFileInfo fi;
			fi.fileName = f.attribute("filename").as_string();
			fi.backupFilePath = f.attribute("backupFilePath").as_string();
			fi.langName = f.attribute("lang").as_string();
			fi.encoding = f.attribute("encoding").as_int(-1);
			fi.firstVisibleLine = f.attribute("firstVisibleLine").as_llong(0);
			fi.xOffset = f.attribute("xOffset").as_llong(0);
			fi.startPos = f.attribute("startPos").as_llong(0);
			fi.endPos = f.attribute("endPos").as_llong(0);
			fi.userReadOnly = std::strcmp(f.attribute("userReadOnly").as_string(), "yes") == 0;
			fi.untitleTabRenamed = std::strcmp(f.attribute("untitleTabRenamed").as_string(), "yes") == 0;
			fi.tabColour = f.attribute("tabColourId").as_int(-1);
			fi.tabPinned = std::strcmp(f.attribute("tabPinned").as_string(), "yes") == 0;
			long long lo = f.attribute("originalFileLastModifTimestamp").as_llong(0);
			long long hi = f.attribute("originalFileLastModifTimestampHigh").as_llong(0);
			fi.originalFileLastModifTimestamp = (hi << 32) | (lo & 0xFFFFFFFF);
			for (pugi::xml_node m = f.child("Mark"); m; m = m.next_sibling("Mark"))
				fi.marks.push_back(m.attribute("line").as_llong());
			for (pugi::xml_node m = f.child("Fold"); m; m = m.next_sibling("Fold"))
				fi.folds.push_back(m.attribute("line").as_llong());
			files.push_back(fi);
		}
	};
	readView(s.child("mainView"), session.mainViewFiles, session.activeMainIndex);
	readView(s.child("subView"), session.subViewFiles, session.activeSubIndex);
	return true;
}

bool NppConfig::saveSession(const std::string& path, const Session& session)
{
	pugi::xml_document doc;
	pugi::xml_node decl = doc.append_child(pugi::node_declaration);
	decl.append_attribute("version") = "1.0";
	decl.append_attribute("encoding") = "UTF-8";
	pugi::xml_node s = doc.append_child("NotepadPlus").append_child("Session");
	s.append_attribute("activeView") = session.activeView;
	auto writeView = [](pugi::xml_node view, const std::vector<SessionFileInfo>& files, int active) {
		view.append_attribute("activeIndex") = active;
		for (const auto& fi : files)
		{
			pugi::xml_node f = view.append_child("File");
			f.append_attribute("firstVisibleLine") = (long long)fi.firstVisibleLine;
			f.append_attribute("xOffset") = (long long)fi.xOffset;
			f.append_attribute("scrollWidth") = 1;
			f.append_attribute("startPos") = (long long)fi.startPos;
			f.append_attribute("endPos") = (long long)fi.endPos;
			f.append_attribute("selMode") = 0;
			f.append_attribute("offset") = 0;
			f.append_attribute("wrapCount") = 1;
			f.append_attribute("lang") = fi.langName.c_str();
			f.append_attribute("encoding") = fi.encoding;
			f.append_attribute("userReadOnly") = fi.userReadOnly ? "yes" : "no";
			f.append_attribute("filename") = fi.fileName.c_str();
			f.append_attribute("backupFilePath") = fi.backupFilePath.c_str();
			f.append_attribute("originalFileLastModifTimestamp") = (long long)(fi.originalFileLastModifTimestamp & 0xFFFFFFFF);
			f.append_attribute("originalFileLastModifTimestampHigh") = (long long)(fi.originalFileLastModifTimestamp >> 32);
			f.append_attribute("tabColourId") = fi.tabColour;
			f.append_attribute("tabPinned") = fi.tabPinned ? "yes" : "no";
			if (fi.untitleTabRenamed)
				f.append_attribute("untitleTabRenamed") = "yes";
			for (long m : fi.marks)
				f.append_child("Mark").append_attribute("line") = (long long)m;
			for (long m : fi.folds)
				f.append_child("Fold").append_attribute("line") = (long long)m;
		}
	};
	writeView(s.append_child("mainView"), session.mainViewFiles, session.activeMainIndex);
	writeView(s.append_child("subView"), session.subViewFiles, session.activeSubIndex);
	return doc.save_file(path.c_str(), "    ");
}
