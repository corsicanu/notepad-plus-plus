#include "NppUpstream.h"

#include <cstring>
#include <map>
#include <string>

namespace
{
	constexpr WinMenuKeyDefinition kWinKeyDefs[]
	{
#include "WinKeyDefs.inc"
	};

	constexpr ScintillaKeyDefinition kScintKeyDefs[]
	{
#include "ScintKeyDefs.inc"
	};

	const ToolbarIconDef kToolbarIcons[]
	{
#include "ToolbarIcons.inc"
	};

	const MenuItemUnitDef kTabContextMenu[]
	{
#include "TabContextMenu.inc"
	};

	struct NamedId { const char* name; int id; };
	const NamedId kMenuIds[]
	{
#include "MenuIds.inc"
	};
}

#include "MenuID2LangType.inc"

namespace NppUpstream
{
	const WinMenuKeyDefinition* winKeyDefs(size_t& count)
	{
		count = std::size(kWinKeyDefs);
		return kWinKeyDefs;
	}

	const ScintillaKeyDefinition* scintKeyDefs(size_t& count)
	{
		count = std::size(kScintKeyDefs);
		return kScintKeyDefs;
	}

	const ToolbarIconDef* toolbarIcons(size_t& count)
	{
		count = std::size(kToolbarIcons);
		return kToolbarIcons;
	}

	const MenuItemUnitDef* defaultTabContextMenu(size_t& count)
	{
		count = std::size(kTabContextMenu);
		return kTabContextMenu;
	}

	int menuIdByName(const char* name)
	{
		static const std::map<std::string, int> ids = [] {
			std::map<std::string, int> m;
			for (const auto& n : kMenuIds)
				m[n.name] = n.id;
			return m;
		}();
		auto it = ids.find(name);
		return it == ids.end() ? -1 : it->second;
	}
}
