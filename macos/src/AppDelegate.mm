// Application entry: builds the menu bar from upstream's Notepad_plus.rc
// (plus the standard macOS application menu) and routes file-open
// requests from Finder and the command line.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "NppMainWindow.h"
#import "NppMenuBuilder.h"
#import "NppTheme.h"
#import "NppLocalization.h"
#import "NppShortcutMapper.h"

@interface NppMainWindow (MacroMenus)
+ (void)installShortcutsXmlItemsIn:(NSMenu*)bar;
- (void)restoreDockingState;
- (void)captureDockingState;
- (BOOL)confirmCloseProjectPanels;
- (NSArray*)allEditors;
@end

#include "LangManager.h"
#include "NppConfig.h"
#include "NppShortcuts.h"
#include "NppSettings.h"
#include "NppUpstream.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

// Test runs (--snapshot / --quit-after) must never block on a modal alert:
// print it and take the first button instead.
@implementation NSAlert (NppTestRun)
- (NSModalResponse)npp_testRunModal
{
	fprintf(stderr, "[alert] %s %s\n", self.messageText.UTF8String, self.informativeText.UTF8String);
	return NSAlertFirstButtonReturn;
}
@end

static void enableNonBlockingAlerts()
{
	Method a = class_getInstanceMethod(NSAlert.class, @selector(runModal));
	Method b = class_getInstanceMethod(NSAlert.class, @selector(npp_testRunModal));
	method_exchangeImplementations(a, b);
}

@implementation AppDelegate
{
	NppMainWindow* _main;
	NSMutableArray<NSString*>* _pendingOpen;
	NSMenu* _fileMenu;
	NSMutableArray<NSMenuItem*>* _recentItems;
	BOOL _noSession;   // test runs (--snapshot, --dump-menus, -nosession) leave the session alone
}

static NSMenuItem* item(NSString* title, SEL action, NSString* key, NSEventModifierFlags mods = NSEventModifierFlagCommand)
{
	NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: title action: action keyEquivalent: key ?: @""];
	mi.keyEquivalentModifierMask = mods;
	return mi;
}

static NSMenuItem* command(NSString* title, int cmd, NSString* key = nil, NSEventModifierFlags mods = NSEventModifierFlagCommand)
{
	NSMenuItem* mi = item(title, @selector(nppCommand:), key, mods);
	mi.tag = cmd;
	return mi;
}

- (void)buildMenus
{
	NSMenu* bar = [[NSMenu alloc] init];

	// macOS application menu; its commands map to Notepad++ ones where they exist.
	NSMenuItem* appItem = [[NSMenuItem alloc] init];
	NSMenu* app = [[NSMenu alloc] initWithTitle: @"Notepad++"];
	[app addItem: command(@"About Notepad++", IDM_ABOUT)];
	[app addItem: NSMenuItem.separatorItem];
	[app addItem: command(@"Preferences...", IDM_SETTING_PREFERENCE, @",")];
	[app addItem: NSMenuItem.separatorItem];
	NSMenu* services = [[NSMenu alloc] init];
	NSMenuItem* servicesItem = item(@"Services", nil, nil);
	servicesItem.submenu = services;
	NSApp.servicesMenu = services;
	[app addItem: servicesItem];
	[app addItem: NSMenuItem.separatorItem];
	[app addItem: item(@"Hide Notepad++", @selector(hide:), nil)];
	[app addItem: item(@"Hide Others", @selector(hideOtherApplications:), nil)];
	[app addItem: item(@"Show All", @selector(unhideAllApplications:), nil)];
	[app addItem: NSMenuItem.separatorItem];
	[app addItem: item(@"Quit Notepad++", @selector(terminate:), @"q")];
	appItem.submenu = app;
	[bar addItem: appItem];

	// Notepad++'s own menus, straight from the resource script.
	NSString* rc = [NSBundle.mainBundle pathForResource: @"Notepad_plus" ofType: @"rc"];
	NSMenu* windowMenu = nil;
	NSMenu* helpMenu = nil;
	// The .rc holds two Language menus; like Notepad_plus::init, keep the
	// compact (A-Z) one or the flat one according to langMenuCompact.
	BOOL compact = NppSettings::instance()._langMenuCompact;
	int languageSeen = 0;
	for (NSMenuItem* top in [NppMenuBuilder mainMenuItemsFromRC: rc])
	{
		if ([top.title isEqualToString: @"Language"] && languageSeen++ != (compact ? 1 : 0))
			continue;
		[bar addItem: top];
		NSString* t = top.title;
		if ([t isEqualToString: @"File"])
		{
			_fileMenu = top.submenu;
			_fileMenu.delegate = self;
		}
		else if ([t isEqualToString: @"Window"])
			windowMenu = top.submenu;
		else if ([t isEqualToString: @"?"])
			helpMenu = top.submenu;
	}

	[NppMenuBuilder applyDefaultShortcuts: bar];
	[NppLocalization applyToMainMenu: bar topOffset: 1];
	[NppMainWindow installShortcutsXmlItemsIn: bar];
	[NppShortcutMapper applyMenuShortcuts: bar];
	NSApp.mainMenu = bar;
	// After the bar is installed, so AppKit doesn't add its own "Window" menu
	// when the localized title differs.
	NSApp.windowsMenu = windowMenu;
	NSApp.helpMenu = helpMenu;
}

// Recent files sit in the File menu above "Exit", like Notepad++'s lastRecentFileList.
- (void)menuNeedsUpdate:(NSMenu*)menu
{
	if (menu != _fileMenu)
		return;
	for (NSMenuItem* mi in _recentItems)
		[menu removeItem: mi];
	_recentItems = [NSMutableArray array];

	NSInteger exitIdx = [menu indexOfItemWithTag: IDM_FILE_EXIT];
	if (exitIdx < 0)
		return;
	NSArray<NSString*>* recents = [NppMainWindow recentFiles];
	NSMutableArray* items = [NSMutableArray array];
	[items addObject: command(@"Restore Recent Closed File", IDM_FILE_RESTORELASTCLOSEDFILE, @"t", NSEventModifierFlagCommand | NSEventModifierFlagShift)];
	for (NSUInteger i = 0; i < recents.count; ++i)
	{
		NSMenuItem* mi = item([NSString stringWithFormat: @"%lu: %@", i + 1, recents[i]], @selector(openRecent:), nil);
		mi.representedObject = recents[i];
		mi.target = self;
		[items addObject: mi];
	}
	if (recents.count)
	{
		[items addObject: NSMenuItem.separatorItem];
		[items addObject: command(@"Open All Recent Files", IDM_OPEN_ALL_RECENT_FILE)];
		[items addObject: command(@"Empty Recent Files List", IDM_CLEAN_RECENT_FILE_LIST)];
	}
	[items addObject: NSMenuItem.separatorItem];
	for (NSMenuItem* mi in items)
	{
		[menu insertItem: mi atIndex: exitIdx++];
		[_recentItems addObject: mi];
	}
}

- (void)openRecent:(NSMenuItem*)sender
{
	[_main openPaths: @[sender.representedObject]];
}

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
	NppConfig::instance().load();
	NppShortcuts::instance().load();
	LangManager::instance().load(NSBundle.mainBundle.resourcePath.fileSystemRepresentation);
	[NppLocalization loadLanguage];
	[self buildMenus];
	// Changing the language rebuilds the menu bar from the .rc, then translates it.
	[NSNotificationCenter.defaultCenter addObserverForName: NppLanguageChangedNotification object: nil queue: nil
	                                            usingBlock: ^(NSNotification*) { [self buildMenus]; }];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
	[NppTheme applyMode];
	// "Follow macOS": restyle when the system appearance changes.
	[NSApp addObserver: self forKeyPath: @"effectiveAppearance" options: 0 context: nil];
	_main = [[NppMainWindow alloc] init];
	[_main showWindow: nil];
	[NppShortcutMapper applyScintillaKeys: [(id)_main allEditors]];

	// Command line: Notepad++ [--snapshot out.png] [--cmd ID]... file1 file2 ...
	NSMutableArray* paths = [NSMutableArray array];
	NSMutableArray* commands = [NSMutableArray array];
	NSArray* args = NSProcessInfo.processInfo.arguments;
	if ([args containsObject: @"--snapshot"] || [args containsObject: @"--quit-after"])
		enableNonBlockingAlerts();
	NSString* snapshot = nil;
	BOOL dumpMenus = NO;
	for (NSUInteger i = 1; i < args.count; ++i)
	{
		if ([args[i] isEqualToString: @"--snapshot"] && i + 1 < args.count)
			snapshot = args[++i];
		else if ([args[i] isEqualToString: @"--quit-after"] && i + 1 < args.count)
			[NSApp performSelector: @selector(terminate:) withObject: nil afterDelay: [args[++i] doubleValue]];
		else if ([args[i] isEqualToString: @"--dump-menus"])
			dumpMenus = YES;
		else if ([args[i] isEqualToString: @"--cmd"] && i + 1 < args.count)
			[commands addObject: @([args[++i] intValue])];
		else if ([args[i] isEqualToString: @"--insert"] && i + 1 < args.count)
			[commands addObject: @[@"insert", args[++i]]];
		else if ([args[i] isEqualToString: @"--macro-save"] && i + 1 < args.count)
			[commands addObject: @[@"macrosave", args[++i]]];
		else if ([args[i] isEqualToString: @"--print-pdf"] && i + 1 < args.count)
			[commands addObject: @[@"printpdf", args[++i]]];
		else if ([args[i] isEqualToString: @"--print-state"])
			[commands addObject: @[@"state", @""]];
		else if ([args[i] isEqualToString: @"--type"] && i + 1 < args.count)
			[commands addObject: @[@"type", args[++i]]];
		else if ([args[i] isEqualToString: @"--run"] && i + 1 < args.count)
			[commands addObject: @[@"run", args[++i]]];
		else if ([args[i] hasPrefix: @"--find-"] && i + 1 < args.count)
		{
			// Test hooks for the Find dialog: --find-text/--find-replace/--find-dir/--find-filters/--find-dlg
			NSString* key = [args[i] substringFromIndex: 7];
			NSString* val = args[++i];
			[commands addObject: @[key, val]];
		}
		else if (![args[i] hasPrefix: @"-"])
			[paths addObject: [args[i] stringByStandardizingPath]];
	}
	if (_pendingOpen)
		[paths addObjectsFromArray: _pendingOpen];
	_pendingOpen = nil;
	if (NppSettings::instance()._rememberLastSession && ![args containsObject: @"-nosession"] && !dumpMenus)
		[_main loadSessionFromPath: [NSString stringWithUTF8String: NppConfig::instance().sessionPath().c_str()]];
	if (paths.count)
		[_main openPaths: paths];
	if (![args containsObject: @"-nosession"] && !snapshot && !dumpMenus)
		[(id)_main restoreDockingState];
	for (id c in commands)
	{
		if ([c isKindOfClass: NSNumber.class])
			[_main runCommand: [c intValue]];
		else
			[_main runFindTestHook: c[0] value: c[1]];
	}
	_noSession = snapshot || dumpMenus || [args containsObject: @"-nosession"];
	if (dumpMenus)
	{
		[self dumpMenu: NSApp.mainMenu depth: 0];
		[NSApp terminate: nil];
	}
	if (snapshot)
		[self performSelector: @selector(writeSnapshot:) withObject: snapshot afterDelay: 1.5];
}

// Prints the menu tree: "+" = command ported, "-" = not ported yet (disabled).
- (void)dumpMenu:(NSMenu*)menu depth:(int)depth
{
	[menu update];
	for (NSMenuItem* mi in menu.itemArray)
	{
		if (mi.separatorItem)
			continue;
		BOOL enabled = mi.action == @selector(nppCommand:) ? [_main validateMenuItem: mi] : YES;
		NSString* key = mi.keyEquivalent.length ? [NSString stringWithFormat: @"  [%@%@%@%@]",
			(mi.keyEquivalentModifierMask & NSEventModifierFlagControl) ? @"^" : @"",
			(mi.keyEquivalentModifierMask & NSEventModifierFlagOption) ? @"⌥" : @"",
			(mi.keyEquivalentModifierMask & NSEventModifierFlagShift) ? @"⇧" : @"",
			(mi.keyEquivalentModifierMask & NSEventModifierFlagCommand) ? [@"⌘" stringByAppendingString: mi.keyEquivalent] : mi.keyEquivalent] : @"";
		printf("%*s%s %s%s (%ld)%s\n", depth * 2, "", mi.submenu ? ">" : enabled ? "+" : "-", mi.state == NSControlStateValueOn ? "✓ " : "",
		       mi.title.UTF8String, (long)mi.tag, key.UTF8String);
		if (mi.submenu)
			[self dumpMenu: mi.submenu depth: depth + 1];
	}
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if (NppSettings::instance()._darkModeFollowOS)
		[NppTheme applyMode];
}

// Renders every visible app window side by side into one PNG and quits;
// lets scripts check the UI without screen-recording permission.
- (void)writeSnapshot:(NSString*)path
{
	NSMutableArray* images = [NSMutableArray array];
	for (NSWindow* w in NSApp.windows)
	{
		if (!w.visible)
			continue;
		NSView* view = w.contentView;
		NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect: view.bounds];
		[view cacheDisplayInRect: view.bounds toBitmapImageRep: rep];
		NSImage* img = [[NSImage alloc] initWithSize: view.bounds.size];
		[img addRepresentation: rep];
		[images addObject: img];
	}
	CGFloat wSum = 0, hMax = 0;
	for (NSImage* i in images)
	{
		wSum += i.size.width + 10;
		hMax = MAX(hMax, i.size.height);
	}
	NSImage* all = [[NSImage alloc] initWithSize: NSMakeSize(MAX(wSum, 1), MAX(hMax, 1))];
	[all lockFocus];
	[NSColor.grayColor setFill];
	NSRectFill(NSMakeRect(0, 0, wSum, hMax));
	CGFloat x = 0;
	for (NSImage* i in images)
	{
		[i drawAtPoint: NSMakePoint(x, hMax - i.size.height) fromRect: NSZeroRect operation: NSCompositingOperationSourceOver fraction: 1];
		x += i.size.width + 10;
	}
	[all unlockFocus];
	NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithData: all.TIFFRepresentation];
	[[out representationUsingType: NSBitmapImageFileTypePNG properties: @{}] writeToFile: path atomically: YES];
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

// Port of Notepad_plus::fileCloseAll / saveSession on exit: in snapshot mode
// nothing is asked, unsaved changes go to backup files restored next time.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
	const NppSettings& s = NppSettings::instance();
	BOOL snapshot = s._isSnapshotMode && s._rememberLastSession;
	if (!snapshot && ![_main confirmCloseAll])
		return NSTerminateCancel;
	if (![(id)_main confirmCloseProjectPanels])
		return NSTerminateCancel;
	if (s._rememberLastSession && !_noSession)
		[_main saveSessionToPath: [NSString stringWithUTF8String: NppConfig::instance().sessionPath().c_str()] withBackups: snapshot];
	[_main captureEditorSettings];
	// Test runs leave the user's panel layout alone.
	if (!_noSession)
		[(id)_main captureDockingState];
	NppConfig::instance().save();
	return NSTerminateNow;
}

// Menu commands reach the main window even while a panel (Find, ...) is key.
- (void)nppCommand:(id)sender
{
	[_main nppCommand: sender];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
	if (menuItem.action == @selector(nppCommand:))
		return [_main validateMenuItem: menuItem];
	return YES;
}

@end

int main(int argc, const char* argv[])
{
	@autoreleasepool
	{
		// argv is parsed by AppDelegate; don't let AppKit also turn it into open-file events.
		[NSUserDefaults.standardUserDefaults registerDefaults: @{@"NSTreatUnknownArgumentsAsOpen": @"NO"}];
		NSApplication* app = NSApplication.sharedApplication;
		AppDelegate* delegate = [[AppDelegate alloc] init];
		app.delegate = delegate;
		[app setActivationPolicy: NSApplicationActivationPolicyRegular];
		[app run];
	}
	return 0;
}
