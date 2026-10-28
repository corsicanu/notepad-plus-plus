// Stand-in for PowerEditor's NppXml.h (pugixml wrappers). Paths built with
// Windows separators ("dir\\file.xml") are turned into POSIX ones.
#pragma once

#include "../../src/NppXml.h"   // pugixml with the app's configuration
#include "Common.h"

#include <string>

namespace NppXml
{
	using NewDocument = pugi::xml_document;
	using Document = pugi::xml_document*;
	using Element = pugi::xml_node;
	using Node = pugi::xml_node;

	inline std::string posixPath(const wchar_t* filename);

	[[nodiscard]] inline bool loadFile(Document doc, const wchar_t* filename)
	{
		return doc->load_file(posixPath(filename).c_str(), pugi::parse_default | pugi::parse_comments | pugi::parse_declaration);
	}

	[[nodiscard]] inline bool loadFileFunctionParser(Document doc, const wchar_t* filename)
	{
		return doc->load_file(posixPath(filename).c_str(), pugi::parse_cdata | pugi::parse_escapes | pugi::parse_eol);
	}

	[[nodiscard]] inline Element firstChildElement(const Document& doc, const char* name = nullptr)
	{
		return name ? doc->child(name) : doc->first_child();
	}

	[[nodiscard]] inline Element firstChildElement(const Node& node, const char* name = nullptr)
	{
		return name ? node.child(name) : node.first_child();
	}

	[[nodiscard]] inline Element nextSiblingElement(const Node& node, const char* name = nullptr)
	{
		return name ? node.next_sibling(name) : node.next_sibling();
	}

	[[nodiscard]] inline const char* attribute(const Element& elem, const char* name, const char* defaultValue = nullptr)
	{
		return elem.attribute(name).as_string(defaultValue);
	}

	[[nodiscard]] inline int intAttribute(const Element& elem, const char* name, int defaultValue = 0)
	{
		return elem.attribute(name).as_int(defaultValue);
	}
}

std::string NppXml::posixPath(const wchar_t* filename)
{
	std::wstring w(filename);
	for (auto& c : w)
		if (c == L'\\')
			c = L'/';
	return wstring2string(w);
}
