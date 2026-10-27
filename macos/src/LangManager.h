// Languages and styles: Notepad++'s langs.xml / stylers.xml (or a theme
// file), applied to Scintilla views like ScintillaEditView::defineDocType()
// and setStyle() do. Styles are editable (Style Configurator) and written
// back into the same XML document, keeping its layout.
#pragma once

#include <map>
#include <string>
#include <vector>

#include "NppUpstream.h"   // LANG_INDEX_*, FONTSTYLE_*

#import "ScintillaView.h"

enum { NB_KEYWORD_LIST = LANG_INDEX_SUBSTYLE1 + 8 };

struct NppStyle
{
	std::string name;              // styleDesc ("COMMENT LINE", "Global override", ...)
	int styleID = -1;
	int fgColor = -1;              // 0xRRGGBB, -1 = not set
	int bgColor = -1;
	int colorStyle = COLORSTYLE_ALL;
	std::string fontName;
	int fontStyle = -1;
	int fontSize = -1;
	int keywordClass = -1;
	std::string keywords;          // user-defined keywords (element text)
	bool fontEnabled = true;       // some global styles only carry colours
};

struct LexerStyler
{
	std::string name;              // "cpp"
	std::string desc;              // "C++"
	std::string userExt;           // "ext" attribute
	std::vector<NppStyle> styles;
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

// <GUIConfig name="globalOverride">.
struct GlobalOverride
{
	bool enableFg = false, enableBg = false, enableFont = false, enableFontSize = false;
	bool enableBold = false, enableItalic = false, enableUnderLine = false;
	bool isEnable() const { return enableFg || enableBg || enableFont || enableFontSize || enableBold || enableItalic || enableUnderLine; }
};

class LangManager
{
public:
	static LangManager& instance();

	// langs.xml (copied from the bundled langs.model.xml when missing) and stylers.
	void load(const std::string& resourceDir);

	const std::vector<NppLang>& languages() const { return _langs; }
	const NppLang* languageByName(const std::string& name) const;
	const NppLang* languageForPath(const std::string& path) const;
	const NppLang* languageByType(int langType) const;
	int langTypeOf(const NppLang* lang) const;

	// ---- Styles / themes ----
	bool loadStyles(const std::string& path);
	bool saveStyles();
	const std::string& stylesPath() const { return _stylesPath; }
	std::string userStylersPath() const;
	// Theme files: "stylers.xml" plus every themes/*.xml (user dir first, then bundle).
	std::vector<std::pair<std::string, std::string>> themes() const;   // (name, path)
	std::string themePathForName(const std::string& fileName) const;

	std::vector<LexerStyler>& lexers() { return _lexers; }
	std::vector<NppStyle>& globalStyles() { return _globalStyles; }
	const NppStyle* globalStyle(const std::string& name) const;
	const LexerStyler* lexerStyler(const std::string& name) const;
	GlobalOverride globalOverride;

	// Sets lexer, keyword lists, styles and folding properties.
	void apply(ScintillaView* view, const NppLang* lang) const;

private:
	void applyGlobalStyles(ScintillaView* view) const;
	void applyStyle(ScintillaView* view, const NppStyle& s) const;
	std::string keywordList(const NppLang* lang, int kwClass, const std::string& lexerStylerName) const;

	std::vector<NppLang> _langs;
	std::vector<LexerStyler> _lexers;
	std::vector<NppStyle> _globalStyles;
	std::string _stylesPath;
	std::string _resourceDir;
};
