// Loads Notepad++'s langs.model.xml / stylers.model.xml and applies
// lexers, keywords and styles to a Scintilla view, following
// ScintillaEditView::defineDocType() in PowerEditor.
#pragma once

#include <map>
#include <string>
#include <vector>

#import "ScintillaView.h"

// Keyword classes, same order as LANG_INDEX_* in PowerEditor/src/MISC/Common/NppConstants.h
enum { LANG_INDEX_INSTR = 0, LANG_INDEX_INSTR2, LANG_INDEX_TYPE, LANG_INDEX_TYPE2, LANG_INDEX_TYPE3,
       LANG_INDEX_TYPE4, LANG_INDEX_TYPE5, LANG_INDEX_TYPE6, LANG_INDEX_TYPE7,
       LANG_INDEX_SUBSTYLE1, NB_KEYWORD_LIST = LANG_INDEX_SUBSTYLE1 + 8 };

enum { FONTSTYLE_BOLD = 1, FONTSTYLE_ITALIC = 2, FONTSTYLE_UNDERLINE = 4 };

struct NppStyle
{
	std::string name;
	int styleID = -1;
	int fgColor = -1;    // 0xRRGGBB, -1 = not set
	int bgColor = -1;
	std::string fontName;
	int fontStyle = -1;
	int fontSize = -1;
	int keywordClass = -1;
};

struct NppLang
{
	std::string name;       // langs.xml name, e.g. "cpp"
	std::string displayName;
	std::string lexer;      // Lexilla lexer name
	std::vector<std::string> extensions;
	std::string keywords[NB_KEYWORD_LIST];
	std::string commentLine, commentStart, commentEnd;
};

class LangManager
{
public:
	static LangManager& instance();

	void load(const std::string& resourceDir);

	const std::vector<NppLang>& languages() const { return _langs; }
	const NppLang* languageByName(const std::string& name) const;
	const NppLang* languageForPath(const std::string& path) const;
	const NppStyle* globalStyle(const std::string& name) const;

	// Sets lexer, keyword lists, styles and folding properties.
	void apply(ScintillaView* view, const NppLang* lang) const;

private:
	void applyGlobalStyles(ScintillaView* view) const;
	void applyStyle(ScintillaView* view, const NppStyle& s) const;

	std::vector<NppLang> _langs;
	std::map<std::string, std::vector<NppStyle>> _lexerStyles;
	std::vector<NppStyle> _globalStyles;
};
