// User Defined Languages: port of UserLangContainer and its parts of
// NppParameters (feedUserLang, insertUserLang2Tree, import / export,
// getUserDefinedLangNameFromExt) and ScintillaEditView::setUserLexer.
#pragma once

#import "ScintillaView.h"

#include "LangManager.h"

#include <memory>
#include <string>
#include <vector>

struct NppUdlStyle : NppStyle
{
	int nesting = 0;
};

struct NppUserLang
{
	std::string name;
	std::string ext;
	std::string udlVersion;
	bool isDarkModeTheme = false;

	bool isCaseIgnored = false;
	bool allowFoldOfComments = false;
	bool foldCompact = false;
	int forcePureLC = 0;
	int decimalSeparator = 0;
	bool isPrefix[SCE_USER_TOTAL_KEYWORD_GROUPS] = {};
	std::string keywordLists[SCE_USER_KWLIST_TOTAL];
	std::vector<NppUdlStyle> styles;   // SCE_USER_STYLE_DEFAULT .. SCE_USER_STYLE_TOTAL_STYLES

	std::string file;                  // where it is saved (userDefineLang.xml or userDefineLangs/x.xml)

	NppUdlStyle* style(int styleID);
	// A fresh language: every style present with upstream's names (UserLangContainer ctor).
	static std::unique_ptr<NppUserLang> makeNew(const std::string& name);
};

class NppUdlManager
{
public:
	static NppUdlManager& instance();

	// userDefineLang.xml and userDefineLangs/*.xml in the settings folder;
	// upstream's preinstalled UDLs (markdown) are copied there the first time.
	void load();
	// Writes every UDL file that holds a changed language.
	bool save();

	const std::vector<std::unique_ptr<NppUserLang>>& languages() const { return _langs; }
	NppUserLang* byName(const std::string& name) const;
	// UDL for a file name, by its "ext" list (dark / light variant like upstream).
	NppUserLang* forPath(const std::string& path) const;

	NppUserLang* add(std::unique_ptr<NppUserLang> lang);   // saved in userDefineLang.xml
	void remove(NppUserLang* lang);
	bool rename(NppUserLang* lang, const std::string& newName);
	int importFile(const std::string& path);                // number of languages added
	bool exportLang(const NppUserLang* lang, const std::string& path) const;
	void markDirty(const NppUserLang* lang);

	std::string folder() const;        // userDefineLangs
	std::string defaultFile() const;   // userDefineLang.xml

private:
	std::vector<std::unique_ptr<NppUserLang>> _langs;
	std::vector<std::string> _dirtyFiles;
	int readFile(const std::string& path);
};

// ScintillaEditView::setUserLexer
void nppApplyUserLang(ScintillaView* view, const NppUserLang& lang, const void* bufferId);
