#import "NppUdl.h"
#import "NppTheme.h"

#include "NppConfig.h"
#include "ILexer.h"
#include "Lexilla.h"
#include "UserDefineResource.h"
#include "NppUpstream.h"

#include <algorithm>
#include <cstring>
#include <unordered_map>

// keyword / style name tables, extracted from UserDefineDialog.h
#include "GlobalMappers.inc"

namespace
{
	GlobalMappers& globalMappper()
	{
		static GlobalMappers gm;
		return gm;
	}

	constexpr size_t kMaxChar = 1024 * 30;   // upstream max_char

	bool yes(const pugi::xml_node& n, const char* attr)
	{
		return std::strcmp(n.attribute(attr).as_string(), "yes") == 0;
	}

	std::string lower(std::string s)
	{
		std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
		return s;
	}

	// NppParameters::feedUserSettings / feedUserKeywordList / feedUserStyles.
	std::unique_ptr<NppUserLang> readUserLang(const pugi::xml_node& node)
	{
		std::string name = node.attribute("name").as_string("");
		if (name.empty())
			return nullptr;
		auto ul = std::make_unique<NppUserLang>();
		ul->name = name;
		ul->ext = node.attribute("ext").as_string("");
		ul->udlVersion = node.attribute("udlVersion").as_string("");
		ul->isDarkModeTheme = yes(node, "darkModeTheme");

		pugi::xml_node settings = node.child("Settings");
		pugi::xml_node kwls = node.child("KeywordLists");
		pugi::xml_node styles = node.child("Styles");
		if (!settings || !kwls || !styles)
			return nullptr;

		if (pugi::xml_node g = settings.child("Global"))
		{
			ul->isCaseIgnored = yes(g, "caseIgnored");
			ul->allowFoldOfComments = yes(g, "allowFoldOfComments");
			ul->forcePureLC = g.attribute("forcePureLC").as_int(0);
			ul->decimalSeparator = g.attribute("decimalSeparator").as_int(0);
			ul->foldCompact = yes(g, "foldCompact");
		}
		if (pugi::xml_node p = settings.child("Prefix"))
		{
			if (ul->udlVersion == "2.1" || ul->udlVersion == "2.0")
			{
				for (int i = 0; i < SCE_USER_TOTAL_KEYWORD_GROUPS; ++i)
					ul->isPrefix[i] = yes(p, globalMappper().keywordNameMapper[i + SCE_USER_KWLIST_KEYWORDS1].c_str());
			}
			else
			{
				static const char* const names[] = {"words1", "words2", "words3", "words4"};
				for (int i = 0; i < 4; ++i)
					ul->isPrefix[i] = yes(p, names[i]);
			}
		}

		for (pugi::xml_node k = kwls.child("Keywords"); k; k = k.next_sibling("Keywords"))
		{
			std::string kwName = k.attribute("name").as_string("");
			const char* kwl = k.child_value();
			if (!kwl || !*kwl)
				continue;
			if (ul->udlVersion.empty() && kwName == "Delimiters" && std::strlen(kwl) >= 6)
			{
				// pre 2.0 delimiters
				std::string temp;
				temp += "00"; if (kwl[0] != '0') temp += kwl[0]; temp += " 01";
				temp += " 02"; if (kwl[3] != '0') temp += kwl[3];
				temp += " 03"; if (kwl[1] != '0') temp += kwl[1]; temp += " 04";
				temp += " 05"; if (kwl[4] != '0') temp += kwl[4];
				temp += " 06"; if (kwl[2] != '0') temp += kwl[2]; temp += " 07";
				temp += " 08"; if (kwl[5] != '0') temp += kwl[5];
				temp += " 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23";
				ul->keywordLists[SCE_USER_KWLIST_DELIMITERS] = temp;
			}
			else if (kwName == "Comment")
			{
				// pre 2.0 comments
				std::string temp = std::string(" ") + kwl;
				for (size_t pos = temp.find(" 0"); pos != std::string::npos; pos = temp.find(" 0", pos + 1))
					temp.replace(pos, 2, " 00");
				for (size_t pos = temp.find(" 1"); pos != std::string::npos; pos = temp.find(" 1"))
					temp.replace(pos, 2, " 03");
				for (size_t pos = temp.find(" 2"); pos != std::string::npos; pos = temp.find(" 2"))
					temp.replace(pos, 2, " 04");
				temp += " 01 02";
				if (temp[0] == ' ')
					temp.erase(0, 1);
				ul->keywordLists[SCE_USER_KWLIST_COMMENTS] = temp;
			}
			else
			{
				auto it = globalMappper().keywordIdMapper.find(kwName);
				if (it != globalMappper().keywordIdMapper.end())
					ul->keywordLists[it->second] = std::strlen(kwl) < kMaxChar ? kwl : "imported string too long, needs to be < max_char(30720)";
			}
		}

		for (pugi::xml_node s = styles.child("WordsStyle"); s; s = s.next_sibling("WordsStyle"))
		{
			std::string styleName = s.attribute("name").as_string("");
			auto it = globalMappper().styleIdMapper.find(styleName);
			if (it == globalMappper().styleIdMapper.end())
				continue;
			NppUdlStyle st;
			static_cast<NppStyle&>(st) = LangManager::styleFromXml(s);
			st.styleID = it->second;
			st.nesting = s.attribute("nesting").as_int(0);
			ul->styles.push_back(st);
		}
		// Styles missing from the file get defaults.
		for (int i = 0; i < SCE_USER_STYLE_TOTAL_STYLES; ++i)
			if (!ul->style(i))
			{
				NppUdlStyle st;
				st.styleID = i;
				st.name = globalMappper().styleNameMapper[i];
				ul->styles.push_back(st);
			}
		return ul;
	}

	// NppParameters::insertUserLang2Tree
	void writeUserLang(pugi::xml_node parent, const NppUserLang& ul)
	{
		pugi::xml_node root = parent.append_child("UserLang");
		root.append_attribute("name") = ul.name.c_str();
		root.append_attribute("ext") = ul.ext.c_str();
		if (ul.isDarkModeTheme)
			root.append_attribute("darkModeTheme") = "yes";
		root.append_attribute("udlVersion") = (std::to_string(SCE_UDL_VERSION_MAJOR) + "." + std::to_string(SCE_UDL_VERSION_MINOR)).c_str();

		pugi::xml_node settings = root.append_child("Settings");
		pugi::xml_node g = settings.append_child("Global");
		g.append_attribute("caseIgnored") = ul.isCaseIgnored ? "yes" : "no";
		g.append_attribute("allowFoldOfComments") = ul.allowFoldOfComments ? "yes" : "no";
		g.append_attribute("foldCompact") = ul.foldCompact ? "yes" : "no";
		g.append_attribute("forcePureLC") = ul.forcePureLC;
		g.append_attribute("decimalSeparator") = ul.decimalSeparator;
		pugi::xml_node p = settings.append_child("Prefix");
		for (int i = 0; i < SCE_USER_TOTAL_KEYWORD_GROUPS; ++i)
			p.append_attribute(globalMappper().keywordNameMapper[i + SCE_USER_KWLIST_KEYWORDS1].c_str()) = ul.isPrefix[i] ? "yes" : "no";

		pugi::xml_node kwl = root.append_child("KeywordLists");
		for (int i = 0; i < SCE_USER_KWLIST_TOTAL; ++i)
		{
			pugi::xml_node k = kwl.append_child("Keywords");
			k.append_attribute("name") = globalMappper().keywordNameMapper[i].c_str();
			k.append_child(pugi::node_pcdata).set_value(ul.keywordLists[i].c_str());
		}

		pugi::xml_node styles = root.append_child("Styles");
		for (const NppUdlStyle& s : ul.styles)
		{
			if (s.styleID == -1)
				continue;
			pugi::xml_node w = styles.append_child("WordsStyle");
			w.append_attribute("name") = s.name.c_str();
			char buf[16];
			snprintf(buf, sizeof(buf), "%.6X", s.fgColor >= 0 ? s.fgColor : 0);
			w.append_attribute("fgColor") = buf;
			snprintf(buf, sizeof(buf), "%.6X", s.bgColor >= 0 ? s.bgColor : 0xFFFFFF);
			w.append_attribute("bgColor") = buf;
			if (s.colorStyle != COLORSTYLE_ALL)
				w.append_attribute("colorStyle") = s.colorStyle;
			if (!s.fontName.empty())
				w.append_attribute("fontName") = s.fontName.c_str();
			w.append_attribute("fontStyle") = s.fontStyle == -1 ? 0 : s.fontStyle;
			if (s.fontSize != -1)
				w.append_attribute("fontSize") = s.fontSize == 0 ? "" : std::to_string(s.fontSize).c_str();
			w.append_attribute("nesting") = s.nesting;
		}
	}

	bool sameFile(const std::string& a, const std::string& b)
	{
		return [@(a.c_str()).stringByStandardizingPath isEqualToString: @(b.c_str()).stringByStandardizingPath];
	}
}

NppUdlStyle* NppUserLang::style(int styleID)
{
	for (auto& s : styles)
		if (s.styleID == styleID)
			return &s;
	return nullptr;
}

std::unique_ptr<NppUserLang> NppUserLang::makeNew(const std::string& name)
{
	auto ul = std::make_unique<NppUserLang>();
	ul->name = name;
	ul->udlVersion = std::to_string(SCE_UDL_VERSION_MAJOR) + "." + std::to_string(SCE_UDL_VERSION_MINOR);
	for (int i = 0; i < SCE_USER_STYLE_TOTAL_STYLES; ++i)
	{
		NppUdlStyle st;
		st.styleID = i;
		st.name = globalMappper().styleNameMapper[i];
		ul->styles.push_back(st);
	}
	return ul;
}

#pragma mark - Manager

NppUdlManager& NppUdlManager::instance()
{
	static NppUdlManager m;
	return m;
}

std::string NppUdlManager::folder() const
{
	return NppConfig::instance().userDir() + "/userDefineLangs";
}

std::string NppUdlManager::defaultFile() const
{
	return NppConfig::instance().userDir() + "/userDefineLang.xml";
}

int NppUdlManager::readFile(const std::string& path)
{
	pugi::xml_document doc;
	if (!doc.load_file(path.c_str()))
		return 0;
	int n = 0;
	for (pugi::xml_node u = doc.child("NotepadPlus").child("UserLang"); u; u = u.next_sibling("UserLang"))
	{
		if (_langs.size() >= static_cast<size_t>(IDM_LANG_USER_LIMIT - IDM_LANG_USER - 1))
			break;
		if (auto ul = readUserLang(u))
		{
			ul->file = path;
			_langs.push_back(std::move(ul));
			++n;
		}
	}
	return n;
}

void NppUdlManager::load()
{
	_langs.clear();
	NSFileManager* fm = NSFileManager.defaultManager;
	NSString* dir = @(folder().c_str());
	// The installer puts the preinstalled UDLs (markdown) in the user's folder.
	if (![fm fileExistsAtPath: dir])
	{
		[fm createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
		NSString* bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: @"userDefineLangs"];
		for (NSString* f in [fm contentsOfDirectoryAtPath: bundled error: nil])
			[fm copyItemAtPath: [bundled stringByAppendingPathComponent: f] toPath: [dir stringByAppendingPathComponent: f] error: nil];
	}
	readFile(defaultFile());
	NSArray* files = [[fm contentsOfDirectoryAtPath: dir error: nil] sortedArrayUsingSelector: @selector(localizedCaseInsensitiveCompare:)];
	for (NSString* f in files)
		if ([f.pathExtension.lowercaseString isEqualToString: @"xml"])
			readFile([dir stringByAppendingPathComponent: f].fileSystemRepresentation);
}

void NppUdlManager::markDirty(const NppUserLang* lang)
{
	if (lang && std::find(_dirtyFiles.begin(), _dirtyFiles.end(), lang->file) == _dirtyFiles.end())
		_dirtyFiles.push_back(lang->file);
}

// NppParameters::writeNeed2SaveUDL: a file is rewritten with all its languages.
bool NppUdlManager::save()
{
	bool ok = true;
	for (const std::string& file : _dirtyFiles)
	{
		pugi::xml_document doc;
		pugi::xml_node decl = doc.append_child(pugi::node_declaration);
		decl.append_attribute("version") = "1.0";
		decl.append_attribute("encoding") = "UTF-8";
		pugi::xml_node root = doc.append_child("NotepadPlus");
		int n = 0;
		for (const auto& l : _langs)
			if (sameFile(l->file, file))
			{
				writeUserLang(root, *l);
				++n;
			}
		if (n == 0)
		{
			// The last language of a userDefineLangs file was removed.
			if (!sameFile(file, defaultFile()))
			{
				[NSFileManager.defaultManager removeItemAtPath: @(file.c_str()) error: nil];
				continue;
			}
		}
		ok &= doc.save_file(file.c_str(), "    ");
	}
	_dirtyFiles.clear();
	return ok;
}

NppUserLang* NppUdlManager::byName(const std::string& name) const
{
	for (const auto& l : _langs)
		if (l->name == name)
			return l.get();
	return nullptr;
}

// NppParameters::getUserDefinedLangNameFromExt: by extension, or by the
// whole file name when an entry has a dot; the dark / light variant matching
// the current mode wins.
NppUserLang* NppUdlManager::forPath(const std::string& path) const
{
	NSString* p = @(path.c_str());
	std::string ext = lower(p.pathExtension.UTF8String ?: "");
	std::string fullName = lower(p.lastPathComponent.UTF8String ?: "");
	NppUserLang* matched = nullptr;
	bool dark = [NppTheme isDark];
	for (const auto& l : _langs)
	{
		std::string list = lower(l->ext);
		size_t pos = 0;
		while (pos < list.size())
		{
			size_t end = list.find(' ', pos);
			if (end == std::string::npos)
				end = list.size();
			std::string e = list.substr(pos, end - pos);
			pos = end + 1;
			if (e.empty())
				continue;
			if ((!ext.empty() && e == ext) || (fullName.find('.') != std::string::npos && e == fullName))
			{
				matched = l.get();
				if (l->isDarkModeTheme == dark)
					return l.get();
			}
		}
	}
	return matched;
}

NppUserLang* NppUdlManager::add(std::unique_ptr<NppUserLang> lang)
{
	if (lang->file.empty())
		lang->file = defaultFile();
	_langs.push_back(std::move(lang));
	markDirty(_langs.back().get());
	return _langs.back().get();
}

void NppUdlManager::remove(NppUserLang* lang)
{
	markDirty(lang);
	_langs.erase(std::remove_if(_langs.begin(), _langs.end(), [lang](const auto& l) { return l.get() == lang; }), _langs.end());
}

bool NppUdlManager::rename(NppUserLang* lang, const std::string& newName)
{
	if (newName.empty() || byName(newName))
		return false;
	lang->name = newName;
	markDirty(lang);
	return true;
}

// importUDLFromFile: imported languages join userDefineLang.xml.
int NppUdlManager::importFile(const std::string& path)
{
	size_t before = _langs.size();
	readFile(path);
	for (size_t i = before; i < _langs.size(); ++i)
	{
		_langs[i]->file = defaultFile();
		markDirty(_langs[i].get());
	}
	return static_cast<int>(_langs.size() - before);
}

bool NppUdlManager::exportLang(const NppUserLang* lang, const std::string& path) const
{
	pugi::xml_document doc;
	pugi::xml_node decl = doc.append_child(pugi::node_declaration);
	decl.append_attribute("version") = "1.0";
	decl.append_attribute("encoding") = "UTF-8";
	writeUserLang(doc.append_child("NotepadPlus"), *lang);
	return doc.save_file(path.c_str(), "    ");
}

#pragma mark - setUserLexer

void nppApplyUserLang(ScintillaView* view, const NppUserLang& ul, const void* bufferId)
{
	auto prop = [view](const char* name, const std::string& value) {
		[view setLexerProperty: @(name) value: @(value.c_str())];
	};
	auto sci = [view](unsigned int m, uptr_t w, sptr_t l) { return [ScintillaView directCall: view message: m wParam: w lParam: l]; };

	const LangManager& lm = LangManager::instance();
	lm.apply(view, lm.languageByName("user"));   // lexer "user" + global styles
	if (!lm.languageByName("user"))
		sci(SCI_SETILEXER, 0, reinterpret_cast<sptr_t>(CreateLexer("user")));

	prop("fold", "1");
	prop("userDefine.isCaseIgnored", ul.isCaseIgnored ? "1" : "0");
	prop("userDefine.allowFoldOfComments", ul.allowFoldOfComments ? "1" : "0");
	prop("userDefine.foldCompact", ul.foldCompact ? "1" : "0");
	for (int i = 0; i < SCE_USER_TOTAL_KEYWORD_GROUPS; ++i)
		prop(("userDefine.prefixKeywords" + std::to_string(i + 1)).c_str(), ul.isPrefix[i] ? "1" : "0");

	int setKeywordsCounter = 0;
	for (int i = 0; i < SCE_USER_KWLIST_TOTAL; ++i)
	{
		const std::string& kw = ul.keywordLists[i];
		auto it = globalMappper().setLexerMapper.find(i);
		if (it != globalMappper().setLexerMapper.end())
		{
			prop(it->second.c_str(), kw);
			continue;
		}
		// OPERATORS2, FOLDERS_IN_CODE2, FOLDERS_IN_COMMENT, KEYWORDS1-8: quoted
		// entries keep their inner spaces as \v (double quotes) / \b (single quotes).
		std::string temp;
		bool inDoubleQuote = false, inSingleQuote = false, nonWSFound = false;
		for (size_t j = 0, len = kw.size(); j < len && temp.size() < kMaxChar - 1; ++j)
		{
			char c = kw[j];
			char next = j + 1 < len ? kw[j + 1] : '\0';
			if (!inSingleQuote && c == '"')
			{
				inDoubleQuote = !inDoubleQuote;
				continue;
			}
			if (!inDoubleQuote && c == '\'')
			{
				inSingleQuote = !inSingleQuote;
				continue;
			}
			if (c == '\\' && (next == '"' || next == '\'' || next == '\\'))
			{
				++j;
				temp += kw[j];
				continue;
			}
			if (inDoubleQuote || inSingleQuote)
			{
				if (c > ' ')
				{
					temp += c;
					nonWSFound = true;
				}
				else if (nonWSFound && j > 0 && kw[j - 1] != '"' && next != '"' && next > ' ')
					temp += inDoubleQuote ? '\v' : '\b';
			}
			else
				temp += c;
		}
		[view setReferenceProperty: SCI_SETKEYWORDS parameter: setKeywordsCounter++ value: temp.c_str()];
	}

	prop("userDefine.forcePureLC", std::to_string(ul.forcePureLC));
	prop("userDefine.decimalSeparator", std::to_string(ul.decimalSeparator));
	// LexUser keeps per-language and per-document state keyed by these numbers.
	prop("userDefine.udlName", std::to_string(reinterpret_cast<uintptr_t>(&ul)));
	prop("userDefine.currentBufferID", std::to_string(reinterpret_cast<uintptr_t>(bufferId)));

	for (const NppUdlStyle& s : ul.styles)
	{
		if (s.styleID == -1)
			continue;
		char nesting[32];
		snprintf(nesting, sizeof(nesting), "userDefine.nesting.%02d", s.styleID);
		prop(nesting, std::to_string(s.nesting));
		lm.applyStyle(view, s);
	}
	sci(SCI_COLOURISE, 0, -1);
}
