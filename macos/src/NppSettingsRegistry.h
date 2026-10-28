// Table of NppSettings fields and where they live in config.xml, so the
// Preferences pages and NppConfig share one description of each value.
#pragma once

#include <string>
#include <vector>

struct NppSettingEntry
{
	enum Kind { Bool, BoolShow, Int, Str, TextBool, TextShow, TextStr };
	const char* gui;      // <GUIConfig name="...">
	const char* attr;     // attribute, or nullptr for the element text
	Kind kind;
	void* field;          // bool* / int* / std::string*
};

const std::vector<NppSettingEntry>& nppSettingsRegistry();
