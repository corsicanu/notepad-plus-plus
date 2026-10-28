// Language menu part of User Defined Languages: the languages listed after
// "User-Defined" (IDM_LANG_USER + 1 + i), Open User Defined Language folder,
// the UDL collection site.

#import "NppMainWindowInternal.h"

#include "NppUdl.h"
#include "NppUpstream.h"

#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

@implementation NppMainWindow (UserLangMenu)

+ (void)installUserLangItemsIn:(NSMenu*)bar
{
	__block NSMenu* langMenu = nil;
	__block void (^find)(NSMenu*);
	__block __weak void (^weakFind)(NSMenu*);
	find = ^(NSMenu* m) {
		for (NSMenuItem* mi in m.itemArray)
		{
			if (mi.submenu)
				weakFind(mi.submenu);
			else if (mi.tag == IDM_LANG_USER && mi.action == @selector(nppCommand:) && !langMenu)
				langMenu = m;
		}
	};
	weakFind = find;
	find(bar);
	if (!langMenu)
		return;
	for (NSMenuItem* mi in [langMenu.itemArray copy])
		if ([mi.representedObject isEqual: @"udl"])
			[langMenu removeItem: mi];
	NSInteger pos = [langMenu indexOfItemWithTag: IDM_LANG_USER] + 1;
	const auto& langs = NppUdlManager::instance().languages();
	for (size_t i = 0; i < langs.size(); ++i)
	{
		NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: @(langs[i]->name.c_str()) action: @selector(nppCommand:) keyEquivalent: @""];
		mi.tag = IDM_LANG_USER + 1 + static_cast<int>(i);
		mi.representedObject = @"udl";
		[langMenu insertItem: mi atIndex: pos++];
	}
}

+ (BOOL)isUserLangCommand:(int)cmd
{
	return cmd > IDM_LANG_USER && cmd < IDM_LANG_USER_LIMIT;
}

- (void)runUserLangCommand:(int)cmd
{
	const auto& langs = NppUdlManager::instance().languages();
	size_t i = cmd - IDM_LANG_USER - 1;
	NppBuffer* b = self.currentBuffer;
	if (i >= langs.size() || !b)
		return;
	b.lang = nullptr;
	b.userLangName = @(langs[i]->name.c_str());
	[self applyLanguage: b];
}

- (BOOL)validateUserLangCommand:(NSMenuItem*)item
{
	const auto& langs = NppUdlManager::instance().languages();
	size_t i = item.tag - IDM_LANG_USER - 1;
	NSString* cur = self.currentBuffer.userLangName;
	item.state = (i < langs.size() && cur && langs[i]->name == cur.UTF8String) ? NSControlStateValueOn : NSControlStateValueOff;
	return i < langs.size();
}

+ (void)registerUserLangCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	t[IDM_LANG_OPENUDLDIR] = ^(NppMainWindow*) {
		NSString* dir = @(NppUdlManager::instance().folder().c_str());
		[NSFileManager.defaultManager createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
		[NSWorkspace.sharedWorkspace openURL: [NSURL fileURLWithPath: dir]];
	};
	t[IDM_LANG_UDLCOLLECTION_PROJECT_SITE] = ^(NppMainWindow*) {
		[NSWorkspace.sharedWorkspace openURL: [NSURL URLWithString: @"https://github.com/notepad-plus-plus/userDefinedLanguages"]];
	};
}

@end
