// Stand-in for PowerEditor's MISC/Common/Common.h: what the shimmed upstream sources use.
#pragma once

#include <string>

std::wstring string2wstring(const std::string& rString, unsigned int codepage = 65001);
std::string wstring2string(const std::wstring& rwString, unsigned int codepage = 65001);
