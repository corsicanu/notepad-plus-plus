// Translations from Notepad++'s nativeLang XML files, applied like
// NativeLangSpeaker: main menu (Entries / SubEntries / Commands, using
// upstream's g_menuFolderPositions table) and dialogs by their node name.
// The chosen language is copied to <settings>/nativeLang.xml, as upstream.
#pragma once

#import <Cocoa/Cocoa.h>

@class NppRcDialog;

extern NSNotificationName const NppLanguageChangedNotification;

@interface NppLocalization : NSObject

// Loads <settings>/nativeLang.xml if present.
+ (void)loadLanguage;
// Selects a bundled language file ("french"); "english" removes the override.
+ (void)selectLanguage:(NSString*)name;
+ (NSString*)currentLanguageFile;    // "english" when none

// `topOffset`: menu bar items before Notepad++'s own (the macOS app menu).
+ (void)applyToMainMenu:(NSMenu*)menu topOffset:(NSInteger)topOffset;
// Applies <Dialog><node>: title + every <Item id name> below it.
+ (void)applyToDialog:(NppRcDialog*)dlg node:(NSString*)node;
// Title of a sub-node (Preferences page names): <Dialog><Preference><key title=...>.
+ (NSString*)titleForNode:(NSString*)node child:(NSString*)child;

@end
