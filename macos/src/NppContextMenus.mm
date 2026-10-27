#import "NppContextMenus.h"
#import "NppMenuBuilder.h"

#include "NppConfig.h"
#include "NppUpstream.h"
#include "NppXml.h"

#include <string>
#include <vector>

namespace
{
	struct Item
	{
		int cmd = 0;
		std::string name;     // "ItemNameAs"; empty = main menu label
		std::string folder;   // submenu
	};

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

	NSString* ns(const wchar_t* w)
	{
		if (!w)
			return @"";
		return [[NSString alloc] initWithBytes: w length: wcslen(w) * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding] ?: @"";
	}

	NSMenuItem* findByTag(NSMenu* menu, NSInteger tag)
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			if (mi.submenu)
			{
				if (NSMenuItem* f = findByTag(mi.submenu, tag))
					return f;
			}
			else if (mi.tag == tag)
				return mi;
		}
		return nil;
	}

	NSMenuItem* findByTitle(NSMenu* menu, NSString* title)
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			if (mi.submenu)
			{
				if (NSMenuItem* f = findByTitle(mi.submenu, title))
					return f;
			}
			else if ([mi.title caseInsensitiveCompare: title] == NSOrderedSame)
				return mi;
		}
		return nil;
	}

	// Port of NppParameters::getCmdIdFromMenuEntryItemName (titles compared without mnemonics).
	int cmdFromMenuEntryItemName(NSString* entry, NSString* item)
	{
		for (NSMenuItem* top in NSApp.mainMenu.itemArray)
		{
			if ([top.title caseInsensitiveCompare: [NppMenuBuilder stripMnemonic: entry]] != NSOrderedSame)
				continue;
			NSMenuItem* mi = findByTitle(top.submenu, [NppMenuBuilder stripMnemonic: item]);
			return mi ? (int)mi.tag : -1;
		}
		return -1;
	}

	NSMenu* buildMenu(const std::vector<Item>& items)
	{
		NSMenu* menu = [[NSMenu alloc] init];
		NSMutableDictionary<NSString*, NSMenu*>* folders = [NSMutableDictionary dictionary];
		for (const Item& it : items)
		{
			NSMenu* target = menu;
			if (!it.folder.empty())
			{
				NSString* f = ns(it.folder);
				target = folders[f];
				if (!target)
				{
					target = [[NSMenu alloc] initWithTitle: f];
					folders[f] = target;
					NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle: f action: nil keyEquivalent: @""];
					holder.submenu = target;
					[menu addItem: holder];
				}
			}
			if (it.cmd == 0)
			{
				[target addItem: NSMenuItem.separatorItem];
				continue;
			}
			NSString* title = ns(it.name);
			if (!title.length)
				title = findByTag(NSApp.mainMenu, it.cmd).title ?: @"";
			title = [NppMenuBuilder macTitle: [NppMenuBuilder stripMnemonic: title] command: it.cmd];
			NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: title action: @selector(nppCommand:) keyEquivalent: @""];
			mi.tag = it.cmd;
			[target addItem: mi];
		}
		return menu;
	}

	std::vector<Item> readXml(const std::string& path, const char* rootName)
	{
		std::vector<Item> items;
		pugi::xml_document doc;
		if (!doc.load_file(path.c_str()))
			return items;
		pugi::xml_node cm = doc.child("NotepadPlus").child(rootName);
		for (pugi::xml_node n = cm.child("Item"); n; n = n.next_sibling("Item"))
		{
			Item it;
			it.folder = n.attribute("FolderName").as_string();
			it.name = n.attribute("ItemNameAs").as_string();
			int id = n.attribute("id").as_int(-1);
			if (id >= 0)
				it.cmd = id;
			else
			{
				const char* entry = n.attribute("MenuEntryName").as_string(nullptr);
				const char* item = n.attribute("MenuItemName").as_string(nullptr);
				if (!entry || !item)
					continue; // plugin commands: no plugins yet
				it.cmd = cmdFromMenuEntryItemName(ns(entry), ns(item));
				if (it.cmd < 0)
					continue;
			}
			items.push_back(it);
		}
		return items;
	}
}

@implementation NppContextMenus

+ (NSMenu*)editorContextMenu
{
	std::string path = NppConfig::instance().userDir() + "/contextMenu.xml";
	if (![NSFileManager.defaultManager fileExistsAtPath: ns(path)])
		[[NSData dataWithBytes: CONTEXTMENU_XML_CONTENT length: strlen(CONTEXTMENU_XML_CONTENT)] writeToFile: ns(path) atomically: YES];
	return buildMenu(readXml(path, "ScintillaContextMenu"));
}

+ (NSMenu*)tabContextMenu
{
	std::string path = NppConfig::instance().userDir() + "/tabContextMenu.xml";
	std::vector<Item> items;
	if ([NSFileManager.defaultManager fileExistsAtPath: ns(path)])
		items = readXml(path, "TabContextMenu");
	if (items.empty())
	{
		size_t n = 0;
		const MenuItemUnitDef* defs = NppUpstream::defaultTabContextMenu(n);
		for (size_t i = 0; i < n; ++i)
		{
			Item it;
			it.cmd = defs[i].cmd;
			it.name = ns(defs[i].name).UTF8String;
			it.folder = ns(defs[i].folder).UTF8String;
			items.push_back(it);
		}
	}
	return buildMenu(items);
}

@end
