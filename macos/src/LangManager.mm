#import "LangManager.h"

#include <algorithm>
#include <cstring>

#include "NppXml.h"
#include "Scintilla.h"
#include "SciLexer.h"
#include "ILexer.h"
#include "Lexilla.h"

namespace
{
	// Port of ScintillaEditView::_langNameInfoArray: langs.xml name -> menu name, Lexilla lexer.
	struct LangInfo { const char* name; const char* shortName; const char* lexer; };
	const LangInfo langInfos[] = {
		{"normal", "Normal text", "null"}, {"php", "PHP", "phpscript"}, {"c", "C", "cpp"},
		{"cpp", "C++", "cpp"}, {"cs", "C#", "cpp"}, {"objc", "Objective-C", "objc"},
		{"java", "Java", "cpp"}, {"rc", "RC", "cpp"}, {"html", "HTML", "hypertext"},
		{"xml", "XML", "xml"}, {"makefile", "Makefile", "makefile"}, {"pascal", "Pascal", "pascal"},
		{"batch", "Batch", "batch"}, {"ini", "ini", "props"}, {"nfo", "NFO", "null"},
		{"udf", "udf", "user"}, {"asp", "ASP", "hypertext"}, {"sql", "SQL", "sql"},
		{"vb", "Visual Basic", "vb"}, {"javascript", "Embedded JS", "cpp"}, {"css", "CSS", "css"},
		{"perl", "Perl", "perl"}, {"python", "Python", "python"}, {"lua", "Lua", "lua"},
		{"tex", "TeX", "tex"}, {"fortran", "Fortran free form", "fortran"}, {"bash", "Shell", "bash"},
		{"actionscript", "ActionScript", "cpp"}, {"nsis", "NSIS", "nsis"}, {"tcl", "TCL", "tcl"},
		{"lisp", "Lisp", "lisp"}, {"scheme", "Scheme", "lisp"}, {"asm", "Assembly", "asm"},
		{"diff", "Diff", "diff"}, {"props", "Properties file", "props"}, {"postscript", "PostScript", "ps"},
		{"ruby", "Ruby", "ruby"}, {"smalltalk", "Smalltalk", "smalltalk"}, {"vhdl", "VHDL", "vhdl"},
		{"kix", "KiXtart", "kix"}, {"autoit", "AutoIt", "au3"}, {"caml", "CAML", "caml"},
		{"ada", "Ada", "ada"}, {"verilog", "Verilog", "verilog"}, {"matlab", "MATLAB", "matlab"},
		{"haskell", "Haskell", "haskell"}, {"inno", "Inno Setup", "inno"},
		{"searchResult", "Internal Search", "searchResult"}, {"cmake", "CMake", "cmake"},
		{"yaml", "YAML", "yaml"}, {"cobol", "COBOL", "COBOL"}, {"gui4cli", "Gui4Cli", "gui4cli"},
		{"d", "D", "d"}, {"powershell", "PowerShell", "powershell"}, {"r", "R", "r"},
		{"jsp", "JSP", "hypertext"}, {"coffeescript", "CoffeeScript", "coffeescript"},
		{"json", "json", "json"}, {"javascript.js", "JavaScript", "cpp"},
		{"fortran77", "Fortran fixed form", "f77"}, {"baanc", "BaanC", "baan"}, {"srec", "S-Record", "srec"},
		{"ihex", "Intel HEX", "ihex"}, {"tehex", "Tektronix extended HEX", "tehex"}, {"swift", "Swift", "cpp"},
		{"asn1", "ASN.1", "asn1"}, {"avs", "AviSynth", "avs"}, {"blitzbasic", "BlitzBasic", "blitzbasic"},
		{"purebasic", "PureBasic", "purebasic"}, {"freebasic", "FreeBasic", "freebasic"},
		{"csound", "Csound", "csound"}, {"erlang", "Erlang", "erlang"}, {"escript", "ESCRIPT", "escript"},
		{"forth", "Forth", "forth"}, {"latex", "LaTeX", "latex"}, {"mmixal", "MMIXAL", "mmixal"},
		{"nim", "Nim", "nimrod"}, {"nncrontab", "Nncrontab", "nncrontab"}, {"oscript", "OScript", "oscript"},
		{"rebol", "REBOL", "rebol"}, {"registry", "registry", "registry"}, {"rust", "Rust", "rust"},
		{"spice", "Spice", "spice"}, {"txt2tags", "txt2tags", "txt2tags"},
		{"visualprolog", "Visual Prolog", "visualprolog"}, {"typescript", "TypeScript", "cpp"},
		{"json5", "json5", "json"}, {"mssql", "mssql", "mssql"}, {"gdscript", "GDScript", "gdscript"},
		{"hollywood", "Hollywood", "hollywood"}, {"go", "Go", "cpp"}, {"raku", "Raku", "raku"},
		{"toml", "TOML", "toml"}, {"sas", "SAS", "sas"}, {"errorlist", "ErrorList", "errorlist"},
	};

	const LangInfo* findLangInfo(const std::string& name)
	{
		for (const auto& li : langInfos)
			if (name == li.name)
				return &li;
		return nullptr;
	}

	int keywordClassFromName(const char* str)
	{
		static const char* names[] = {"instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6", "type7"};
		for (int i = 0; i < 9; ++i)
			if (std::strcmp(str, names[i]) == 0)
				return i;
		if (std::strncmp(str, "substyle", 8) == 0 && str[8] >= '1' && str[8] <= '8' && !str[9])
			return LANG_INDEX_SUBSTYLE1 + (str[8] - '1');
		if (str[0] >= '0' && str[0] <= '8' && !str[1])
			return str[0] - '0';
		return -1;
	}

	int parseColor(const char* hex)
	{
		if (!hex || !*hex)
			return -1;
		return static_cast<int>(std::strtol(hex, nullptr, 16));
	}

	int parseInt(const char* s)
	{
		if (!s || !*s)
			return -1;
		return std::atoi(s);
	}

	// Scintilla wants 0xBBGGRR, the XML files store RRGGBB.
	long bgr(int rgb)
	{
		return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
	}

	std::string lower(std::string s)
	{
		std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
		return s;
	}

	std::vector<NppStyle> parseStyles(const pugi::xml_node& parent, const char* childName)
	{
		std::vector<NppStyle> styles;
		for (pugi::xml_node n = parent.child(childName); n; n = n.next_sibling(childName))
		{
			NppStyle s;
			s.name = n.attribute("name").as_string();
			s.styleID = n.attribute("styleID").as_int(-1);
			s.fgColor = parseColor(n.attribute("fgColor").as_string());
			s.bgColor = parseColor(n.attribute("bgColor").as_string());
			s.fontName = n.attribute("fontName").as_string();
			s.fontStyle = parseInt(n.attribute("fontStyle").as_string());
			s.fontSize = parseInt(n.attribute("fontSize").as_string());
			if (const char* kw = n.attribute("keywordClass").as_string(nullptr))
				s.keywordClass = keywordClassFromName(kw);
			styles.push_back(s);
		}
		return styles;
	}

	// Windows point sizes assume 96 DPI; Cocoa uses 72, so keep the same apparent size.
	int macFontSize(int winSize)
	{
		return (winSize * 4 + 1) / 3;
	}
}

LangManager& LangManager::instance()
{
	static LangManager mgr;
	return mgr;
}

void LangManager::load(const std::string& resourceDir)
{
	pugi::xml_document langsDoc;
	if (langsDoc.load_file((resourceDir + "/langs.model.xml").c_str()))
	{
		pugi::xml_node languages = langsDoc.child("NotepadPlus").child("Languages");
		for (pugi::xml_node n = languages.child("Language"); n; n = n.next_sibling("Language"))
		{
			NppLang lang;
			lang.name = n.attribute("name").as_string();
			const LangInfo* info = findLangInfo(lang.name);
			lang.displayName = info ? info->shortName : lang.name;
			lang.lexer = info ? info->lexer : "null";
			lang.commentLine = n.attribute("commentLine").as_string();
			lang.commentStart = n.attribute("commentStart").as_string();
			lang.commentEnd = n.attribute("commentEnd").as_string();

			std::string ext = n.attribute("ext").as_string();
			size_t pos = 0;
			while (pos < ext.size())
			{
				size_t end = ext.find(' ', pos);
				if (end == std::string::npos)
					end = ext.size();
				if (end > pos)
					lang.extensions.push_back(lower(ext.substr(pos, end - pos)));
				pos = end + 1;
			}

			for (pugi::xml_node kw = n.child("Keywords"); kw; kw = kw.next_sibling("Keywords"))
			{
				int cls = keywordClassFromName(kw.attribute("name").as_string());
				if (cls >= 0)
					lang.keywords[cls] = kw.text().as_string();
			}
			_langs.push_back(lang);
		}
	}

	pugi::xml_document stylesDoc;
	if (stylesDoc.load_file((resourceDir + "/stylers.model.xml").c_str()))
	{
		pugi::xml_node root = stylesDoc.child("NotepadPlus");
		pugi::xml_node lexers = root.child("LexerStyles");
		for (pugi::xml_node n = lexers.child("LexerType"); n; n = n.next_sibling("LexerType"))
			_lexerStyles[n.attribute("name").as_string()] = parseStyles(n, "WordsStyle");
		_globalStyles = parseStyles(root.child("GlobalStyles"), "WidgetStyle");
	}
}

const NppLang* LangManager::languageByName(const std::string& name) const
{
	for (const auto& l : _langs)
		if (l.name == name)
			return &l;
	return nullptr;
}

const NppLang* LangManager::languageForPath(const std::string& path) const
{
	std::string file = path.substr(path.find_last_of('/') + 1);
	std::string fileLower = lower(file);

	// Full-name matches first (e.g. "makefile", "CMakeLists.txt"), then extensions.
	for (const auto& l : _langs)
		for (const auto& e : l.extensions)
			if (e == fileLower)
				return &l;

	size_t dot = fileLower.find_last_of('.');
	if (dot == std::string::npos)
		return languageByName("normal");
	std::string ext = fileLower.substr(dot + 1);
	for (const auto& l : _langs)
		for (const auto& e : l.extensions)
			if (e == ext)
				return &l;
	return languageByName("normal");
}

const NppLang* LangManager::languageByType(int langType) const
{
	if (langType < 0 || langType >= (int)std::size(langInfos))
		return nullptr;
	return languageByName(langInfos[langType].name);
}

int LangManager::langTypeOf(const NppLang* lang) const
{
	if (!lang)
		return 0;
	for (size_t i = 0; i < std::size(langInfos); ++i)
		if (lang->name == langInfos[i].name)
			return (int)i;
	return 0;
}

const NppStyle* LangManager::globalStyle(const std::string& name) const
{
	for (const auto& s : _globalStyles)
		if (s.name == name)
			return &s;
	return nullptr;
}

void LangManager::applyStyle(ScintillaView* view, const NppStyle& s) const
{
	int id = s.styleID;
	if (s.fgColor >= 0)
		[view message: SCI_STYLESETFORE wParam: id lParam: bgr(s.fgColor)];
	if (s.bgColor >= 0)
		[view message: SCI_STYLESETBACK wParam: id lParam: bgr(s.bgColor)];
	if (!s.fontName.empty())
		[view message: SCI_STYLESETFONT wParam: id lParam: reinterpret_cast<sptr_t>(s.fontName.c_str())];
	if (s.fontSize > 0)
		[view message: SCI_STYLESETSIZE wParam: id lParam: macFontSize(s.fontSize)];
	if (s.fontStyle >= 0)
	{
		[view message: SCI_STYLESETBOLD wParam: id lParam: (s.fontStyle & FONTSTYLE_BOLD) != 0];
		[view message: SCI_STYLESETITALIC wParam: id lParam: (s.fontStyle & FONTSTYLE_ITALIC) != 0];
		[view message: SCI_STYLESETUNDERLINE wParam: id lParam: (s.fontStyle & FONTSTYLE_UNDERLINE) != 0];
	}
}

void LangManager::applyGlobalStyles(ScintillaView* view) const
{
	// Default style first, then propagate it to every style like Notepad++ does.
	if (const NppStyle* def = globalStyle("Default Style"))
		applyStyle(view, *def);
	[view message: SCI_STYLECLEARALL];

	for (const auto& s : _globalStyles)
		if (s.styleID > 0 && s.styleID != STYLE_DEFAULT && s.styleID >= STYLE_LINENUMBER && s.styleID <= STYLE_LASTPREDEFINED)
			applyStyle(view, s);

	auto color = [this](const char* name, bool fg) -> int {
		const NppStyle* s = globalStyle(name);
		return s ? (fg ? s->fgColor : s->bgColor) : -1;
	};

	int c;
	if ((c = color("Caret colour", true)) >= 0)
		[view message: SCI_SETELEMENTCOLOUR wParam: SC_ELEMENT_CARET lParam: bgr(c) | 0xFF000000];
	if ((c = color("Current line background colour", false)) >= 0)
	{
		[view message: SCI_SETELEMENTCOLOUR wParam: SC_ELEMENT_CARET_LINE_BACK lParam: bgr(c) | 0xFF000000];
		[view message: SCI_SETCARETLINEVISIBLEALWAYS wParam: 1];
	}
	if ((c = color("Selected text colour", false)) >= 0)
	{
		[view message: SCI_SETELEMENTCOLOUR wParam: SC_ELEMENT_SELECTION_BACK lParam: bgr(c) | 0xFF000000];
		[view message: SCI_SETELEMENTCOLOUR wParam: SC_ELEMENT_SELECTION_INACTIVE_BACK lParam: bgr(c) | 0xFF000000];
	}
	if ((c = color("Edge colour", true)) >= 0)
		[view message: SCI_SETEDGECOLOUR wParam: bgr(c)];
	if ((c = color("White space symbol", true)) >= 0)
		[view message: SCI_SETELEMENTCOLOUR wParam: SC_ELEMENT_WHITE_SPACE lParam: bgr(c) | 0xFF000000];
	if ((c = color("Bookmark margin", false)) >= 0)
		[view message: SCI_SETMARGINBACKN wParam: 1 lParam: bgr(c)];

	// Indicator colours (find marks, smart highlighting, mark styles 1-5, tag match).
	for (const auto& s : _globalStyles)
		if (s.styleID >= SCE_UNIVERSAL_FOUND_STYLE_EXT5 && s.styleID <= SCE_UNIVERSAL_FOUND_STYLE && s.bgColor >= 0)
			[view message: SCI_INDICSETFORE wParam: s.styleID lParam: bgr(s.bgColor)];

	const NppStyle* foldMargin = globalStyle("Fold margin");
	if (foldMargin)
	{
		if (foldMargin->bgColor >= 0)
			[view message: SCI_SETFOLDMARGINCOLOUR wParam: 1 lParam: bgr(foldMargin->bgColor)];
		if (foldMargin->fgColor >= 0)
			[view message: SCI_SETFOLDMARGINHICOLOUR wParam: 1 lParam: bgr(foldMargin->fgColor)];
	}
	const NppStyle* fold = globalStyle("Fold");
	const NppStyle* foldActive = globalStyle("Fold active");
	for (int m = SC_MARKNUM_FOLDEREND; m <= SC_MARKNUM_FOLDEROPEN; ++m)
	{
		if (fold && fold->fgColor >= 0)
			[view message: SCI_MARKERSETBACK wParam: m lParam: bgr(fold->fgColor)];
		if (fold && fold->bgColor >= 0)
			[view message: SCI_MARKERSETFORE wParam: m lParam: bgr(fold->bgColor)];
		if (foldActive && foldActive->fgColor >= 0)
			[view message: SCI_MARKERSETBACKSELECTED wParam: m lParam: bgr(foldActive->fgColor)];
	}
}

void LangManager::apply(ScintillaView* view, const NppLang* lang) const
{
	const std::string lexerName = lang ? lang->lexer : "null";
	[view message: SCI_SETILEXER wParam: 0 lParam: reinterpret_cast<sptr_t>(CreateLexer(lexerName.c_str()))];

	applyGlobalStyles(view);
	if (!lang)
		return;

	// Keyword sets: Scintilla set index == LANG_INDEX_* in Notepad++'s generic setLexer().
	// C-family lexers use a different layout (ScintillaEditView::setCppLexer).
	const bool cppFamily = lexerName == "cpp" || lexerName == "objc";
	if (cppFamily)
	{
		const NppLang* cpp = languageByName("cpp");
		[view setReferenceProperty: SCI_SETKEYWORDS parameter: 0 value: lang->keywords[LANG_INDEX_INSTR].c_str()];
		[view setReferenceProperty: SCI_SETKEYWORDS parameter: 1 value: lang->keywords[LANG_INDEX_TYPE].c_str()];
		if (cpp && lang->name != "rc")
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 2 value: cpp->keywords[LANG_INDEX_TYPE2].c_str()];
		[view setReferenceProperty: SCI_SETKEYWORDS parameter: 3 value: lang->keywords[LANG_INDEX_INSTR2].c_str()];
		if (lang->name == "go")
			[view setLexerProperty: @"lexer.cpp.backquoted.strings" value: @"1"];
		[view setLexerProperty: @"lexer.cpp.track.preprocessor" value: @"0"];
	}
	else if (lexerName == "hypertext" || lexerName == "xml")
	{
		// setHTMLLexer/setXmlLexer: HTML tags plus the embedded script languages.
		auto kw = [this](const char* name, int idx) {
			const NppLang* l = languageByName(name);
			return l ? l->keywords[idx].c_str() : "";
		};
		if (lexerName == "hypertext")
		{
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 0 value: kw("html", LANG_INDEX_INSTR)];
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 1 value: kw("javascript", LANG_INDEX_INSTR)];
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 2 value: kw("vb", LANG_INDEX_INSTR)];
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 3 value: kw("python", LANG_INDEX_INSTR)];
			[view setReferenceProperty: SCI_SETKEYWORDS parameter: 4 value: kw("php", LANG_INDEX_INSTR)];
		}
		[view setLexerProperty: @"fold.html" value: @"1"];
		[view setLexerProperty: @"fold.hypertext.comment" value: @"1"];
	}
	else
	{
		for (int i = LANG_INDEX_INSTR; i <= LANG_INDEX_TYPE7; ++i)
			if (!lang->keywords[i].empty())
				[view setReferenceProperty: SCI_SETKEYWORDS parameter: i value: lang->keywords[i].c_str()];
	}

	[view setLexerProperty: @"fold" value: @"1"];
	[view setLexerProperty: @"fold.compact" value: @"0"];
	[view setLexerProperty: @"fold.comment" value: @"1"];
	[view setLexerProperty: @"fold.preprocessor" value: @"1"];

	// Lexer styles: styles.xml names some lexers after the language ("javascript.js"),
	// others after the language entry itself.
	auto it = _lexerStyles.find(lang->name);
	if (it != _lexerStyles.end())
		for (const auto& s : it->second)
			applyStyle(view, s);

	[view message: SCI_COLOURISE wParam: 0 lParam: -1];
}
