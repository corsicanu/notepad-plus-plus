#pragma once

#include <string>
#include <vector>

// 256 rows of: Value, Hex, Character, HTML Name, HTML Decimal, HTML Hexadecimal
// (AsciiListView::setValues). `codepage` 0 is the system ANSI codepage.
std::vector<std::vector<std::wstring>> nppAsciiTable(int codepage);
