// Sort lines with upstream's sorters for an IDM_EDIT_SORTLINES_* command.
#pragma once

#include <string>
#include <vector>
#include "menuCmdID.h"

// Returns false when a numeric sort finds a line it can't parse (as upstream).
bool nppSortLines(std::vector<std::wstring>& lines, int cmd, size_t fromColumn, size_t toColumn);
