// Builds the menu bar from upstream's Notepad_plus.rc (IDR_M30_MENU), so
// menu layout, labels and command IDs match Windows Notepad++ exactly.
// Every item sends -nppCommand: with the Notepad++ command ID as its tag.
#pragma once

#import <Cocoa/Cocoa.h>

@protocol NppCommandTarget
- (void)nppCommand:(id)sender;
@end

@interface NppMenuBuilder : NSObject

// Returns the top-level popups of the main menu, in order ("&File", ...).
+ (NSArray<NSMenuItem*>*)mainMenuItemsFromRC:(NSString*)rcPath;

// Applies Notepad++'s default shortcuts (Parameters.cpp winKeyDefs/scintKeyDefs).
+ (void)applyDefaultShortcuts:(NSMenu*)menu;

// Sets a Notepad++ (Win32 virtual-key) shortcut on an item, mapped like the defaults.
+ (void)setShortcutOf:(NSMenuItem*)mi key:(int)vKey ctrl:(BOOL)ctrl alt:(BOOL)alt shift:(BOOL)shift;

// Windows wording -> macOS wording for a few commands ("Explorer" -> "Finder").
+ (NSString*)macTitle:(NSString*)title command:(int)cmd;

// "&Open..." -> "Open...", "&&" -> "&".
+ (NSString*)stripMnemonic:(NSString*)label;

@end
