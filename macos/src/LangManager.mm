#import "LangManager.h"

#include <algorithm>
#include <cstring>

#include "NppConfig.h"
#include "NppXml.h"
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

	pugi::xml_document g_stylesDoc;

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

	std::vector<std::string> splitSpaces(const std::string& s)
	{
		std::vector<std::string> out;
		size_t pos = 0;
		while (pos < s.size())
		{
			size_t end = s.find(' ', pos);
			if (end == std::string::npos)
				end = s.size();
			if (end > pos)
				out.push_back(lower(s.substr(pos, end - pos)));
			pos = end + 1;
		}
		return out;
	}

	NppStyle parseStyle(pugi::xml_node n)
	{
		NppStyle s;
		s.name = n.attribute("name").as_string();
		s.styleID = n.attribute("styleID").as_int(-1);
		s.fgColor = parseColor(n.attribute("fgColor").as_string());
		s.bgColor = parseColor(n.attribute("bgColor").as_string());
		s.colorStyle = n.attribute("colorStyle").as_int(COLORSTYLE_ALL);
		s.fontName = n.attribute("fontName").as_string();
		s.fontStyle = parseInt(n.attribute("fontStyle").as_string());
		s.fontSize = parseInt(n.attribute("fontSize").as_string());
		s.fontEnabled = n.attribute("fontName") || n.attribute("fontSize") || n.attribute("fontStyle");
		if (const char* kw = n.attribute("keywordClass").as_string(nullptr))
			s.keywordClass = keywordClassFromName(kw);
		s.keywords = n.text().as_string();
		return s;
	}

	// Port of NppParameters::writeStyle2Element.
	void writeStyle(pugi::xml_node n, const NppStyle& s)
	{
		auto set = [&](const char* a, const char* v) {
			pugi::xml_attribute at = n.attribute(a);
			if (!at)
				at = n.append_attribute(a);
			at = v;
		};
		char buf[16];
		if (s.fgColor >= 0)
		{
			snprintf(buf, sizeof(buf), "%.6X", s.fgColor);
			set("fgColor", buf);
		}
		if (s.bgColor >= 0)
		{
			snprintf(buf, sizeof(buf), "%.6X", s.bgColor);
			set("bgColor", buf);
		}
		if (s.colorStyle != COLORSTYLE_ALL)
			set("colorStyle", std::to_string(s.colorStyle).c_str());
		else
			n.remove_attribute("colorStyle");
		if (n.attribute("fontName"))
			set("fontName", s.fontName.c_str());
		if (s.fontSize != -1)
			set("fontSize", s.fontSize == 0 ? "" : std::to_string(s.fontSize).c_str());
		if (s.fontStyle != -1)
			set("fontStyle", std::to_string(s.fontStyle).c_str());
		if (!s.keywords.empty() || n.first_child().type() == pugi::node_pcdata)
			n.text().set(s.keywords.c_str());
	}

	// Windows point sizes assume 96 DPI; Cocoa uses 72, so keep the same apparent size.
	int macFontSize(int winSize)
	{
		return (winSize * 4 + 1) / 3;
	}

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

	// Themes name Windows fonts (Consolas, Lucida Console...). When the font isn't
	// installed, use Menlo so text stays monospaced instead of the system font.
	std::string availableFont(const std::string& name)
	{
		static std::map<std::string, std::string> cache;
		auto it = cache.find(name);
		if (it != cache.end())
			return it->second;
		NSString* n = ns(name);
		BOOL installed = [NSFont fontWithName: n size: 12] != nil ||
		                 [[NSFontManager.sharedFontManager availableFontFamilies] containsObject: n];
		std::string result = installed ? name : "Menlo";
		cache[name] = result;
		return result;
	}
}

LangManager& LangManager::instance()
{
	static LangManager mgr;
	return mgr;
}

std::string LangManager::userStylersPath() const
{
	return NppConfig::instance().userDir() + "/stylers.xml";
}

void LangManager::load(const std::string& resourceDir)
{
	_resourceDir = resourceDir;
	NSFileManager* fm = NSFileManager.defaultManager;
	const std::string& user = NppConfig::instance().userDir();

	// Per-user langs.xml and stylers.xml, created from the model files like NppParameters::load.
	std::string langsPath = user + "/langs.xml";
	if (![fm fileExistsAtPath: ns(langsPath)])
		[fm copyItemAtPath: ns(resourceDir + "/langs.model.xml") toPath: ns(langsPath) error: nil];
	if (![fm fileExistsAtPath: ns(userStylersPath())])
		[fm copyItemAtPath: ns(resourceDir + "/stylers.model.xml") toPath: ns(userStylersPath()) error: nil];

	pugi::xml_document langsDoc;
	if (!langsDoc.load_file(langsPath.c_str()))
		langsDoc.load_file((resourceDir + "/langs.model.xml").c_str());
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
		lang.extensions = splitSpaces(n.attribute("ext").as_string());
		for (pugi::xml_node kw = n.child("Keywords"); kw; kw = kw.next_sibling("Keywords"))
		{
			int cls = keywordClassFromName(kw.attribute("name").as_string());
			if (cls >= 0)
				lang.keywords[cls] = kw.text().as_string();
		}
		_langs.push_back(lang);
	}

	if (!loadStyles(userStylersPath()))
		loadStyles(resourceDir + "/stylers.model.xml");
}

bool LangManager::loadStyles(const std::string& path)
{
	pugi::xml_document doc;
	if (!doc.load_file(path.c_str()))
		return false;
	g_stylesDoc.reset(doc);
	_stylesPath = path;
	_lexers.clear();
	_globalStyles.clear();
	pugi::xml_node root = g_stylesDoc.child("NotepadPlus");
	for (pugi::xml_node n = root.child("LexerStyles").child("LexerType"); n; n = n.next_sibling("LexerType"))
	{
		LexerStyler ls;
		ls.name = n.attribute("name").as_string();
		ls.desc = n.attribute("desc").as_string();
		ls.userExt = n.attribute("ext").as_string();
		for (pugi::xml_node w = n.child("WordsStyle"); w; w = w.next_sibling("WordsStyle"))
			ls.styles.push_back(parseStyle(w));
		_lexers.push_back(ls);
	}
	for (pugi::xml_node w = root.child("GlobalStyles").child("WidgetStyle"); w; w = w.next_sibling("WidgetStyle"))
		_globalStyles.push_back(parseStyle(w));
	return true;
}

bool LangManager::saveStyles()
{
	pugi::xml_node root = g_stylesDoc.child("NotepadPlus");
	size_t li = 0;
	for (pugi::xml_node n = root.child("LexerStyles").child("LexerType"); n && li < _lexers.size(); n = n.next_sibling("LexerType"), ++li)
	{
		const LexerStyler& ls = _lexers[li];
		if (!ls.userExt.empty() || n.attribute("ext"))
		{
			if (!n.attribute("ext"))
				n.append_attribute("ext");
			n.attribute("ext") = ls.userExt.c_str();
		}
		size_t si = 0;
		for (pugi::xml_node w = n.child("WordsStyle"); w && si < ls.styles.size(); w = w.next_sibling("WordsStyle"), ++si)
			writeStyle(w, ls.styles[si]);
	}
	size_t gi = 0;
	for (pugi::xml_node w = root.child("GlobalStyles").child("WidgetStyle"); w && gi < _globalStyles.size(); w = w.next_sibling("WidgetStyle"), ++gi)
		writeStyle(w, _globalStyles[gi]);

	// Themes inside the app bundle are read-only: save them as a user theme instead.
	std::string target = _stylesPath;
	if (target.rfind(_resourceDir, 0) == 0)
	{
		std::string userThemes = NppConfig::instance().userDir() + "/themes";
		[NSFileManager.defaultManager createDirectoryAtPath: ns(userThemes) withIntermediateDirectories: YES attributes: nil error: nil];
		target = userThemes + "/" + target.substr(target.find_last_of('/') + 1);
		_stylesPath = target;
	}
	return g_stylesDoc.save_file(target.c_str(), "    ");
}

std::vector<std::pair<std::string, std::string>> LangManager::themes() const
{
	std::vector<std::pair<std::string, std::string>> out;
	out.push_back({"Default (stylers.xml)", userStylersPath()});
	std::vector<std::string> seen;
	for (const std::string& dir : {NppConfig::instance().userDir() + "/themes", _resourceDir + "/themes"})
	{
		NSArray* files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath: ns(dir) error: nil] sortedArrayUsingSelector: @selector(localizedCaseInsensitiveCompare:)];
		for (NSString* f in files)
		{
			if (![f.pathExtension.lowercaseString isEqualToString: @"xml"])
				continue;
			std::string name = f.stringByDeletingPathExtension.UTF8String;
			if (std::find(seen.begin(), seen.end(), name) != seen.end())
				continue;
			seen.push_back(name);
			out.push_back({name, dir + "/" + f.UTF8String});
		}
	}
	std::sort(out.begin() + 1, out.end(), [](const auto& a, const auto& b) { return lower(a.first) < lower(b.first); });
	return out;
}

std::string LangManager::themePathForName(const std::string& fileName) const
{
	if (fileName.empty() || fileName == "stylers.xml")
		return userStylersPath();
	for (const std::string& dir : {NppConfig::instance().userDir() + "/themes", _resourceDir + "/themes"})
	{
		std::string p = dir + "/" + fileName;
		if ([NSFileManager.defaultManager fileExistsAtPath: ns(p)])
			return p;
	}
	return userStylersPath();
}

const NppLang* LangManager::languageByName(const std::string& name) const
{
	for (const auto& l : _langs)
		if (l.name == name)
			return &l;
	return nullptr;
}

const LexerStyler* LangManager::lexerStyler(const std::string& name) const
{
	for (const auto& l : _lexers)
		if (l.name == name)
			return &l;
	return nullptr;
}

const NppLang* LangManager::languageForPath(const std::string& path) const
{
	std::string file = path.substr(path.find_last_of('/') + 1);
	std::string fileLower = lower(file);
	size_t dot = fileLower.find_last_of('.');
	std::string ext = dot == std::string::npos ? "" : fileLower.substr(dot + 1);

	// User extensions from the Style Configurator win (NppParameters::getLangFromExt).
	if (!ext.empty())
		for (const auto& ls : _lexers)
			for (const auto& e : splitSpaces(ls.userExt))
				if (e == ext)
					if (const NppLang* l = languageByName(ls.name))
						return l;

	// Full-name matches first (e.g. "makefile", "CMakeLists.txt"), then extensions.
	for (const auto& l : _langs)
		for (const auto& e : l.extensions)
			if (e == fileLower)
				return &l;
	if (ext.empty())
		return languageByName("normal");
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

// Port of ScintillaEditView::setStyle, including the Global override.
void LangManager::applyStyle(ScintillaView* view, const NppStyle& in) const
{
	NppStyle s = in;
	const GlobalOverride& go = globalOverride;
	if (go.isEnable())
	{
		if (const NppStyle* g = globalStyle("Global override"))
		{
			if (go.enableFg)
			{
				if (g->colorStyle & COLORSTYLE_FOREGROUND)
				{
					s.colorStyle |= COLORSTYLE_FOREGROUND;
					s.fgColor = g->fgColor;
				}
				else if (s.styleID == STYLE_DEFAULT)
					s.colorStyle |= COLORSTYLE_FOREGROUND;
				else
					s.colorStyle &= ~COLORSTYLE_FOREGROUND;
			}
			if (go.enableBg)
			{
				if (g->colorStyle & COLORSTYLE_BACKGROUND)
				{
					s.colorStyle |= COLORSTYLE_BACKGROUND;
					s.bgColor = g->bgColor;
				}
				else if (s.styleID == STYLE_DEFAULT)
					s.colorStyle |= COLORSTYLE_BACKGROUND;
				else
					s.colorStyle &= ~COLORSTYLE_BACKGROUND;
			}
			if (go.enableFont && !g->fontName.empty())
				s.fontName = g->fontName;
			if (go.enableFontSize && g->fontSize > 0)
				s.fontSize = g->fontSize;
			if (g->fontStyle != -1)
			{
				if (s.fontStyle == -1)
					s.fontStyle = 0;
				auto flag = [&](bool enabled, int bit) {
					if (enabled)
						s.fontStyle = (g->fontStyle & bit) ? (s.fontStyle | bit) : (s.fontStyle & ~bit);
				};
				flag(go.enableBold, FONTSTYLE_BOLD);
				flag(go.enableItalic, FONTSTYLE_ITALIC);
				flag(go.enableUnderLine, FONTSTYLE_UNDERLINE);
			}
		}
	}

	int id = s.styleID;
	if (s.fgColor >= 0 && (s.colorStyle & COLORSTYLE_FOREGROUND))
		[view message: SCI_STYLESETFORE wParam: id lParam: bgr(s.fgColor)];
	if (s.bgColor >= 0 && (s.colorStyle & COLORSTYLE_BACKGROUND))
		[view message: SCI_STYLESETBACK wParam: id lParam: bgr(s.bgColor)];
	if (!s.fontName.empty())
	{
		std::string font = availableFont(s.fontName);
		[view message: SCI_STYLESETFONT wParam: id lParam: reinterpret_cast<sptr_t>(font.c_str())];
	}
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
	auto element = [view](int el, int rgb) {
		[view message: SCI_SETELEMENTCOLOUR wParam: el lParam: bgr(rgb) | 0xFF000000];
	};

	int c;
	if ((c = color("Caret colour", true)) >= 0)
		element(SC_ELEMENT_CARET, c);
	if ((c = color("Multi-edit carets color", true)) >= 0)
		element(SC_ELEMENT_CARET_ADDITIONAL, c);
	if ((c = color("Current line background colour", false)) >= 0)
		element(SC_ELEMENT_CARET_LINE_BACK, c);
	if ((c = color("Selected text colour", false)) >= 0)
	{
		element(SC_ELEMENT_SELECTION_BACK, c);
		element(SC_ELEMENT_SELECTION_INACTIVE_BACK, c);
	}
	if ((c = color("Multi-selected text color", false)) >= 0)
		element(SC_ELEMENT_SELECTION_ADDITIONAL_BACK, c);
	if ((c = color("Edge colour", true)) >= 0)
		[view message: SCI_SETEDGECOLOUR wParam: bgr(c)];
	if ((c = color("White space symbol", true)) >= 0)
		element(SC_ELEMENT_WHITE_SPACE, c);
	if ((c = color("Bookmark margin", false)) >= 0)
		[view message: SCI_SETMARGINBACKN wParam: 1 lParam: bgr(c)];
	if ((c = color("Change History margin", false)) >= 0)
		[view message: SCI_SETMARGINBACKN wParam: 2 lParam: bgr(c)];

	// Change history markers.
	struct { const char* name; int marker; } history[] = {
		{"Change History modified", SC_MARKNUM_HISTORY_MODIFIED},
		{"Change History revert modified", SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED},
		{"Change History revert origin", SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN},
		{"Change History saved", SC_MARKNUM_HISTORY_SAVED},
	};
	for (const auto& h : history)
		if (const NppStyle* s = globalStyle(h.name))
		{
			if (s->fgColor >= 0)
				[view message: SCI_MARKERSETFORE wParam: h.marker lParam: bgr(s->fgColor)];
			if (s->bgColor >= 0)
				[view message: SCI_MARKERSETBACK wParam: h.marker lParam: bgr(s->bgColor)];
		}

	// Indicator colours (find marks, smart highlighting, mark styles 1-5, tag match).
	for (const auto& s : _globalStyles)
		if (s.styleID >= SCE_UNIVERSAL_FOUND_STYLE_EXT5 && s.styleID <= SCE_UNIVERSAL_FOUND_STYLE && s.bgColor >= 0)
			[view message: SCI_INDICSETFORE wParam: s.styleID lParam: bgr(s.bgColor)];

	if (const NppStyle* fm = globalStyle("Fold margin"))
	{
		if (fm->bgColor >= 0)
			[view message: SCI_SETFOLDMARGINCOLOUR wParam: 1 lParam: bgr(fm->bgColor)];
		if (fm->fgColor >= 0)
			[view message: SCI_SETFOLDMARGINHICOLOUR wParam: 1 lParam: bgr(fm->fgColor)];
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

// User keywords (style text) + default keywords, as ScintillaEditView::concatToBuildKeywordList.
std::string LangManager::keywordList(const NppLang* lang, int kwClass, const std::string& lexerStylerName) const
{
	std::string user;
	if (const LexerStyler* ls = lexerStyler(lexerStylerName))
		for (const auto& s : ls->styles)
			if (s.keywordClass == kwClass && !s.keywords.empty())
				user = s.keywords;
	std::string def = lang && kwClass >= 0 && kwClass < NB_KEYWORD_LIST ? lang->keywords[kwClass] : "";
	return user.empty() ? def : user + " " + def;
}

void LangManager::apply(ScintillaView* view, const NppLang* lang) const
{
	const std::string lexerName = lang ? lang->lexer : "null";
	[view message: SCI_SETILEXER wParam: 0 lParam: reinterpret_cast<sptr_t>(CreateLexer(lexerName.c_str()))];

	applyGlobalStyles(view);
	if (!lang)
		return;

	auto setKw = [view](int set, const std::string& words) {
		[view setReferenceProperty: SCI_SETKEYWORDS parameter: set value: words.c_str()];
	};

	// Keyword sets: Scintilla set index == LANG_INDEX_* in Notepad++'s generic setLexer().
	// C-family lexers use a different layout (ScintillaEditView::setCppLexer).
	const bool cppFamily = lexerName == "cpp" || lexerName == "objc";
	if (cppFamily)
	{
		setKw(0, keywordList(lang, LANG_INDEX_INSTR, lang->name));
		setKw(1, keywordList(lang, LANG_INDEX_TYPE, lang->name));
		if (lang->name != "rc")
			if (const NppLang* cpp = languageByName("cpp"))
				setKw(2, cpp->keywords[LANG_INDEX_TYPE2]);
		setKw(3, keywordList(lang, LANG_INDEX_INSTR2, lang->name));
		if (lang->name == "go")
			[view setLexerProperty: @"lexer.cpp.backquoted.strings" value: @"1"];
		[view setLexerProperty: @"lexer.cpp.track.preprocessor" value: @"0"];
	}
	else if (lexerName == "hypertext" || lexerName == "xml")
	{
		// setHTMLLexer/setXmlLexer: HTML tags plus the embedded script languages.
		auto kw = [this](const char* name, int idx) {
			const NppLang* l = languageByName(name);
			return l ? l->keywords[idx] : std::string();
		};
		if (lexerName == "hypertext")
		{
			setKw(0, keywordList(languageByName("html"), LANG_INDEX_INSTR, "html"));
			setKw(1, kw("javascript", LANG_INDEX_INSTR));
			setKw(2, kw("vb", LANG_INDEX_INSTR));
			setKw(3, kw("python", LANG_INDEX_INSTR));
			setKw(4, kw("php", LANG_INDEX_INSTR));
		}
		[view setLexerProperty: @"fold.html" value: @"1"];
		[view setLexerProperty: @"fold.hypertext.comment" value: @"1"];
	}
	else
	{
		for (int i = LANG_INDEX_INSTR; i <= LANG_INDEX_TYPE7; ++i)
		{
			std::string words = keywordList(lang, i, lang->name);
			if (!words.empty())
				setKw(i, words);
		}
	}

	[view setLexerProperty: @"fold" value: @"1"];
	[view setLexerProperty: @"fold.compact" value: @"0"];
	[view setLexerProperty: @"fold.comment" value: @"1"];
	[view setLexerProperty: @"fold.preprocessor" value: @"1"];

	if (const LexerStyler* ls = lexerStyler(lang->name))
		for (const auto& s : ls->styles)
			applyStyle(view, s);

	[view message: SCI_COLOURISE wParam: 0 lParam: -1];
}
