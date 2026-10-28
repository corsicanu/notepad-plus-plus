// Shortcut Mapper (ShortcutMapper) and the shortcuts.xml customizations it
// edits: menu command keys (<InternalCommands>) and Scintilla command keys
// (<ScintillaKeys>).
#pragma once

#import <Cocoa/Cocoa.h>

#include "NppShortcuts.h"

@class NppMainWindow;

// The Shortcut dialog (IDD_SHORTCUT_DLG); NO when cancelled.
bool nppShortcutDialog(NppShortcutEntry& e, NSString* title, BOOL nameEditable);

typedef NS_ENUM(NSInteger, NppShortcutMapperTab) {
	NppShortcutMapperMainMenu = 0,
	NppShortcutMapperMacros,
	NppShortcutMapperRunCommands,
	NppShortcutMapperPluginCommands,
	NppShortcutMapperScintilla,
};

@interface NppShortcutMapper : NSObject
+ (void)showForWindow:(NppMainWindow*)window tab:(NppShortcutMapperTab)tab;

// Applies <InternalCommands> to the menu bar and <ScintillaKeys> to the editors.
+ (void)applyMenuShortcuts:(NSMenu*)bar;
+ (void)applyScintillaKeys:(NSArray*)editors;
@end
