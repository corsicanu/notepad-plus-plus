#import "NppLocalization.h"
#import "NppMenuBuilder.h"
#import "NppRcDialog.h"

#include "NppConfig.h"
#include "NppXml.h"

#include <cstring>

NSNotificationName const NppLanguageChangedNotification = @"NppLanguageChangedNotification";

namespace
{
	struct MenuPosition { int _x; int _y; int _z; const char* _id; };
	const MenuPosition kMenuFolderPositions[] = {
#include "MenuFolderPositions.inc"
	};

	pugi::xml_document g_lang;

	pugi::xml_node nativeLang()
	{
		return g_lang.child("NotepadPlus").child("Native-Langue");
	}

	NSString* ns(const char* s) { return s ? [NSString stringWithUTF8String: s] ?: @"" : @""; }

	NSString* userFile()
	{
		return [NSString stringWithUTF8String: (NppConfig::instance().userDir() + "/nativeLang.xml").c_str()];
	}

	const MenuPosition* position(const char* id)
	{
		for (const auto& p : kMenuFolderPositions)
			if (std::strcmp(p._id, id) == 0)
				return &p;
		return nullptr;
	}

	void setCommandTitle(NSMenu* menu, NSInteger tag, NSString* title)
	{
		for (NSMenuItem* mi in menu.itemArray)
		{
			if (mi.submenu)
				setCommandTitle(mi.submenu, tag, title);
			else if (mi.tag == tag)
				mi.title = title;
		}
	}

	void applyItems(pugi::xml_node node, NppRcDialog* dlg)
	{
		for (pugi::xml_node n = node.first_child(); n; n = n.next_sibling())
		{
			if (std::strcmp(n.name(), "Item") == 0)
			{
				int cid = n.attribute("id").as_int(0);
				const char* name = n.attribute("name").as_string(nullptr);
				if (cid && name && [dlg item: cid])
					[dlg setText: cid value: [NppMenuBuilder stripMnemonic: ns(name)]];
			}
			else if (std::strcmp(n.name(), "Menu") != 0)
				applyItems(n, dlg);
		}
	}
}

@implementation NppLocalization

+ (void)loadLanguage
{
	g_lang.reset();
	g_lang.load_file(userFile().fileSystemRepresentation);
}

+ (NSString*)currentLanguageFile
{
	NSString* f = ns(nativeLang().attribute("filename").as_string(nullptr));
	return f.length ? f.stringByDeletingPathExtension : @"english";
}

+ (void)selectLanguage:(NSString*)name
{
	NSFileManager* fm = NSFileManager.defaultManager;
	[fm removeItemAtPath: userFile() error: nil];
	if (![name isEqualToString: @"english"])
	{
		NSString* src = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: @"localization"]
		                 stringByAppendingPathComponent: [name stringByAppendingPathExtension: @"xml"]];
		[fm copyItemAtPath: src toPath: userFile() error: nil];
	}
	[self loadLanguage];
	[NSNotificationCenter.defaultCenter postNotificationName: NppLanguageChangedNotification object: nil];
}

// Port of NativeLangSpeaker::changeMenuLang.
+ (void)applyToMainMenu:(NSMenu*)menu topOffset:(NSInteger)topOffset
{
	pugi::xml_node main = nativeLang().child("Menu").child("Main");
	if (!main)
		return;
	auto label = [](pugi::xml_node n) { return [NppMenuBuilder stripMnemonic: ns(n.attribute("name").as_string())]; };

	for (pugi::xml_node n = main.child("Entries").child("Item"); n; n = n.next_sibling("Item"))
		if (const MenuPosition* p = position(n.attribute("menuId").as_string()))
		{
			NSInteger x = p->_x + topOffset;
			if (p->_y == -1 && x < menu.numberOfItems)
			{
				NSMenuItem* top = [menu itemAtIndex: x];
				top.title = label(n);
				top.submenu.title = label(n);
			}
		}

	for (pugi::xml_node n = main.child("Commands").child("Item"); n; n = n.next_sibling("Item"))
		setCommandTitle(menu, n.attribute("id").as_int(), label(n));

	for (pugi::xml_node n = main.child("SubEntries").child("Item"); n; n = n.next_sibling("Item"))
	{
		const MenuPosition* p = position(n.attribute("subMenuId").as_string());
		if (!p || p->_y < 0 || p->_x + topOffset >= menu.numberOfItems)
			continue;
		NSMenu* m = [menu itemAtIndex: p->_x + topOffset].submenu;
		if (p->_y >= m.numberOfItems)
			continue;
		NSMenuItem* item = [m itemAtIndex: p->_y];
		if (p->_z >= 0)
		{
			if (!item.submenu || p->_z >= item.submenu.numberOfItems)
				continue;
			item = [item.submenu itemAtIndex: p->_z];
		}
		if (item.submenu)
			item.title = label(n);
	}
}

+ (void)applyToDialog:(NppRcDialog*)dlg node:(NSString*)nodeName
{
	pugi::xml_node node = nativeLang().child("Dialog").child(nodeName.UTF8String);
	if (!node)
		return;
	const char* title = node.attribute("title").as_string(nullptr);
	if (title && *title && dlg.window)
		dlg.window.title = [NppMenuBuilder stripMnemonic: ns(title)];
	applyItems(node, dlg);
}

+ (NSString*)titleForNode:(NSString*)node child:(NSString*)child
{
	pugi::xml_node n = nativeLang().child("Dialog").child(node.UTF8String).child(child.UTF8String);
	const char* t = n.attribute("title").as_string(nullptr);
	return t && *t ? ns(t) : nil;
}

@end
