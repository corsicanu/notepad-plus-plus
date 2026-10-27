// Application entry: menu bar (laid out like Notepad++'s main menu, with
// Ctrl shortcuts mapped to Cmd) and file-open handling from Finder/CLI.

#import <Cocoa/Cocoa.h>
#import "NppMainWindow.h"
#import "NppBuffer.h"

#include "LangManager.h"

#include <map>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation AppDelegate
{
	NppMainWindow* _main;
	NSMutableArray<NSString*>* _pendingOpen;
	NSMenu* _recentMenu;
}

static NSMenuItem* item(NSString* title, SEL action, NSString* key, NSEventModifierFlags mods = NSEventModifierFlagCommand, NSInteger tag = 0)
{
	NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: title action: action keyEquivalent: key ?: @""];
	mi.keyEquivalentModifierMask = mods;
	mi.tag = tag;
	return mi;
}

static NSString* fkey(unichar f)
{
	return [NSString stringWithCharacters: &f length: 1];
}

static NSMenu* submenu(NSMenu* parent, NSString* title)
{
	NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""];
	NSMenu* m = [[NSMenu alloc] initWithTitle: title];
	holder.submenu = m;
	[parent addItem: holder];
	return m;
}

- (void)buildMenus
{
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags cmdShift = cmd | NSEventModifierFlagShift;
	const NSEventModifierFlags cmdAlt = cmd | NSEventModifierFlagOption;
	NSMenu* bar = [[NSMenu alloc] init];

	// Application menu
	NSMenu* app = submenu(bar, @"Notepad++");
	[app addItem: item(@"About Notepad++", @selector(orderFrontStandardAboutPanel:), nil)];
	[app addItem: NSMenuItem.separatorItem];
	NSMenu* services = [[NSMenu alloc] init];
	NSMenuItem* servicesItem = item(@"Services", nil, nil);
	servicesItem.submenu = services;
	NSApp.servicesMenu = services;
	[app addItem: servicesItem];
	[app addItem: NSMenuItem.separatorItem];
	[app addItem: item(@"Hide Notepad++", @selector(hide:), @"h")];
	[app addItem: item(@"Hide Others", @selector(hideOtherApplications:), @"h", cmdAlt)];
	[app addItem: item(@"Show All", @selector(unhideAllApplications:), nil)];
	[app addItem: NSMenuItem.separatorItem];
	[app addItem: item(@"Quit Notepad++", @selector(terminate:), @"q")];

	// File
	NSMenu* file = submenu(bar, @"File");
	[file addItem: item(@"New", @selector(newDocument:), @"n")];
	[file addItem: item(@"Open...", @selector(openDocument:), @"o")];
	NSMenuItem* recent = item(@"Recent Files", nil, nil);
	_recentMenu = [[NSMenu alloc] initWithTitle: @"Recent Files"];
	_recentMenu.delegate = self;
	recent.submenu = _recentMenu;
	[file addItem: recent];
	[file addItem: item(@"Reload from Disk", @selector(reloadFromDisk:), @"r", cmdShift)];
	[file addItem: item(@"Save", @selector(saveDocument:), @"s")];
	[file addItem: item(@"Save As...", @selector(saveDocumentAs:), @"s", cmdAlt)];
	[file addItem: item(@"Save All", @selector(saveAllDocuments:), @"s", cmdShift)];
	[file addItem: NSMenuItem.separatorItem];
	[file addItem: item(@"Close", @selector(closeDocument:), @"w")];
	[file addItem: item(@"Close All", @selector(closeAllDocuments:), @"w", cmdShift)];
	[file addItem: item(@"Close All BUT Current Document", @selector(closeAllButCurrent:), nil)];
	[file addItem: NSMenuItem.separatorItem];
	[file addItem: item(@"Print...", @selector(print:), @"p")];

	// Edit
	NSMenu* edit = submenu(bar, @"Edit");
	[edit addItem: item(@"Undo", @selector(undo:), @"z")];
	[edit addItem: item(@"Redo", @selector(redo:), @"y")];
	[edit addItem: NSMenuItem.separatorItem];
	[edit addItem: item(@"Cut", @selector(cut:), @"x")];
	[edit addItem: item(@"Copy", @selector(copy:), @"c")];
	[edit addItem: item(@"Paste", @selector(paste:), @"v")];
	[edit addItem: item(@"Delete", @selector(delete:), nil)];
	[edit addItem: item(@"Select All", @selector(selectAll:), @"a")];
	[edit addItem: NSMenuItem.separatorItem];
	NSMenu* convCase = submenu(edit, @"Convert Case to");
	[convCase addItem: item(@"UPPERCASE", @selector(toUpperCase:), @"u", cmdShift)];
	[convCase addItem: item(@"lowercase", @selector(toLowerCase:), @"u")];
	NSMenu* lineOps = submenu(edit, @"Line Operations");
	[lineOps addItem: item(@"Duplicate Current Line", @selector(duplicateLine:), @"d")];
	[lineOps addItem: item(@"Delete Current Line", @selector(deleteLine:), @"l", cmdShift)];
	[lineOps addItem: item(@"Join Lines", @selector(joinLines:), @"j")];
	[lineOps addItem: item(@"Move Up Current Line", @selector(moveLineUp:), fkey(NSUpArrowFunctionKey), cmdShift)];
	[lineOps addItem: item(@"Move Down Current Line", @selector(moveLineDown:), fkey(NSDownArrowFunctionKey), cmdShift)];
	NSMenu* comment = submenu(edit, @"Comment/Uncomment");
	[comment addItem: item(@"Toggle Single Line Comment", @selector(toggleComment:), @"/")];

	// Search
	NSMenu* search = submenu(bar, @"Search");
	[search addItem: item(@"Go to...", @selector(goToLine:), @"g")];
	[search addItem: NSMenuItem.separatorItem];
	NSMenu* bookmark = submenu(search, @"Bookmark");
	[bookmark addItem: item(@"Toggle Bookmark", @selector(toggleBookmark:), fkey(NSF2FunctionKey), cmd)];
	[bookmark addItem: item(@"Next Bookmark", @selector(nextBookmark:), fkey(NSF2FunctionKey), 0)];
	[bookmark addItem: item(@"Previous Bookmark", @selector(previousBookmark:), fkey(NSF2FunctionKey), NSEventModifierFlagShift)];
	[bookmark addItem: item(@"Clear All Bookmarks", @selector(clearBookmarks:), nil)];

	// View
	NSMenu* view = submenu(bar, @"View");
	NSMenu* symbols = submenu(view, @"Show Symbol");
	[symbols addItem: item(@"Show Space and Tab", @selector(toggleShowWhitespace:), nil)];
	[symbols addItem: item(@"Show End of Line", @selector(toggleShowEOL:), nil)];
	[symbols addItem: item(@"Show All Characters", @selector(toggleShowAllChars:), nil)];
	[symbols addItem: NSMenuItem.separatorItem];
	[symbols addItem: item(@"Show Indent Guide", @selector(toggleIndentGuides:), nil)];
	NSMenu* zoom = submenu(view, @"Zoom");
	[zoom addItem: item(@"Zoom In", @selector(zoomIn:), @"=")];
	[zoom addItem: item(@"Zoom Out", @selector(zoomOut:), @"-")];
	[zoom addItem: item(@"Restore Default Zoom", @selector(zoomRestore:), @"0")];
	[view addItem: NSMenuItem.separatorItem];
	[view addItem: item(@"Word wrap", @selector(toggleWordWrap:), nil)];
	[view addItem: NSMenuItem.separatorItem];
	[view addItem: item(@"Fold All", @selector(foldAll:), @"0", cmdAlt)];
	[view addItem: item(@"Unfold All", @selector(unfoldAll:), @"0", cmdAlt | NSEventModifierFlagShift)];
	[view addItem: NSMenuItem.separatorItem];
	[view addItem: item(@"Enter Full Screen", @selector(toggleFullScreen:), @"f", cmd | NSEventModifierFlagControl)];
	NSMenu* tab = submenu(view, @"Tab");
	[tab addItem: item(@"Next Tab", @selector(nextTab:), @"\t", NSEventModifierFlagControl)];
	[tab addItem: item(@"Previous Tab", @selector(previousTab:), @"\t", NSEventModifierFlagControl | NSEventModifierFlagShift)];

	// Encoding
	NSMenu* enc = submenu(bar, @"Encoding");
	for (NppEncoding e : {NppEncodingANSI, NppEncodingUTF8, NppEncodingUTF8BOM, NppEncodingUTF16BE, NppEncodingUTF16LE})
		[enc addItem: item([NSString stringWithFormat: @"%@", e == NppEncodingANSI ? @"ANSI" : [NppBuffer encodingName: e]],
		                   @selector(setEncodingFromMenu:), nil, 0, e)];
	[enc addItem: NSMenuItem.separatorItem];
	NSMenu* eol = submenu(enc, @"EOL Conversion");
	[eol addItem: item(@"Windows (CR LF)", @selector(setEOLFromMenu:), nil, 0, NppEOLWindows)];
	[eol addItem: item(@"Unix (LF)", @selector(setEOLFromMenu:), nil, 0, NppEOLUnix)];
	[eol addItem: item(@"Macintosh (CR)", @selector(setEOLFromMenu:), nil, 0, NppEOLMac)];

	// Language: "Normal Text" then A-Z submenus, like Notepad++.
	NSMenu* language = submenu(bar, @"Language");
	const auto& langs = LangManager::instance().languages();
	std::map<char, NSMenu*> letters;
	for (size_t i = 0; i < langs.size(); ++i)
	{
		const NppLang& l = langs[i];
		if (l.name == "searchResult" || l.name == "udf" || l.name == "javascript")
			continue;
		NSMenuItem* mi = item([NSString stringWithUTF8String: l.displayName.c_str()], @selector(setLanguageFromMenu:), nil, 0, i);
		if (l.name == "normal")
		{
			[language insertItem: mi atIndex: 0];
			continue;
		}
		char letter = std::toupper(l.displayName[0]);
		if (!letters[letter])
			letters[letter] = [[NSMenu alloc] initWithTitle: [NSString stringWithFormat: @"%c", letter]];
		[letters[letter] addItem: mi];
	}
	[language addItem: NSMenuItem.separatorItem];
	for (auto& [letter, menu] : letters)
	{
		NSArray* sorted = [menu.itemArray sortedArrayUsingComparator: ^(NSMenuItem* a, NSMenuItem* b) {
			return [a.title localizedCaseInsensitiveCompare: b.title];
		}];
		[menu removeAllItems];
		for (NSMenuItem* m in sorted)
			[menu addItem: m];
		NSMenuItem* holder = item([NSString stringWithFormat: @"%c", letter], nil, nil);
		holder.submenu = menu;
		[language addItem: holder];
	}

	// Window / Help
	NSMenu* window = submenu(bar, @"Window");
	[window addItem: item(@"Minimize", @selector(performMiniaturize:), @"m")];
	[window addItem: item(@"Zoom", @selector(performZoom:), nil)];
	NSApp.windowsMenu = window;
	NSMenu* help = submenu(bar, @"?");
	[help addItem: item(@"Notepad++ Home", @selector(openHomepage:), nil)];
	NSApp.helpMenu = help;

	NSApp.mainMenu = bar;
}

// Notepad++ keeps its own recent file list (File menu), not the system one.
- (void)menuNeedsUpdate:(NSMenu*)menu
{
	if (menu != _recentMenu)
		return;
	[menu removeAllItems];
	NSArray<NSString*>* recents = [NppMainWindow recentFiles];
	for (NSUInteger i = 0; i < recents.count; ++i)
	{
		NSMenuItem* mi = item([NSString stringWithFormat: @"%lu: %@", i + 1, recents[i]], @selector(openRecent:), nil);
		mi.representedObject = recents[i];
		mi.target = self;
		[menu addItem: mi];
	}
	if (recents.count)
		[menu addItem: NSMenuItem.separatorItem];
	NSMenuItem* clear = item(@"Empty Recent Files List", @selector(clearRecent:), nil);
	clear.target = self;
	[menu addItem: clear];
}

- (void)openRecent:(NSMenuItem*)sender
{
	[_main openPaths: @[sender.representedObject]];
}

- (void)clearRecent:(id)sender
{
	[NppMainWindow clearRecentFiles];
}

- (void)openHomepage:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: @"https://notepad-plus-plus.org/"]];
}

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
	LangManager::instance().load(NSBundle.mainBundle.resourcePath.fileSystemRepresentation);
	[self buildMenus];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
	_main = [[NppMainWindow alloc] init];
	[_main showWindow: nil];

	// Command line: Notepad++ [--snapshot out.png] file1 file2 ...
	NSMutableArray* paths = [NSMutableArray array];
	NSArray* args = NSProcessInfo.processInfo.arguments;
	NSString* snapshot = nil;
	for (NSUInteger i = 1; i < args.count; ++i)
	{
		if ([args[i] isEqualToString: @"--snapshot"] && i + 1 < args.count)
			snapshot = args[++i];
		else if (![args[i] hasPrefix: @"-"])
			[paths addObject: [args[i] stringByStandardizingPath]];
	}
	if (snapshot)
		[self performSelector: @selector(writeSnapshot:) withObject: snapshot afterDelay: 1.5];
	if (_pendingOpen)
		[paths addObjectsFromArray: _pendingOpen];
	_pendingOpen = nil;
	if (paths.count)
		[_main openPaths: paths];
}

// Renders the main window to a PNG and quits; used by scripts/snapshot.sh
// to check the UI without screen-recording permission.
- (void)writeSnapshot:(NSString*)path
{
	NSView* view = _main.window.contentView;
	NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect: view.bounds];
	[view cacheDisplayInRect: view.bounds toBitmapImageRep: rep];
	[[rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}] writeToFile: path atomically: YES];
	[NSApp terminate: nil];
}

- (void)application:(NSApplication*)sender openFiles:(NSArray<NSString*>*)filenames
{
	if (_main)
		[_main openPaths: filenames];
	else
	{
		if (!_pendingOpen)
			_pendingOpen = [NSMutableArray array];
		[_pendingOpen addObjectsFromArray: filenames];
	}
	[sender replyToOpenOrPrint: NSApplicationDelegateReplySuccess];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag
{
	[_main showWindow: nil];
	return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
	return [_main confirmCloseAll] ? NSTerminateNow : NSTerminateCancel;
}

// File-menu actions reach the window controller through the responder chain
// only when it is key; forward them so they also work while a panel is open.
- (id)forwardingTargetForSelector:(SEL)sel
{
	return [_main respondsToSelector: sel] ? _main : nil;
}

- (BOOL)respondsToSelector:(SEL)sel
{
	return [super respondsToSelector: sel] || [_main respondsToSelector: sel];
}

@end

int main(int argc, const char* argv[])
{
	@autoreleasepool
	{
		NSApplication* app = NSApplication.sharedApplication;
		AppDelegate* delegate = [[AppDelegate alloc] init];
		app.delegate = delegate;
		[app setActivationPolicy: NSApplicationActivationPolicyRegular];
		[app run];
	}
	return 0;
}
