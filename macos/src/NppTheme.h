// Light/dark mode and theme selection, after Notepad++'s DarkMode
// settings: Light, Dark, or Follow the OS ("Follow Windows" upstream).
// Switching mode switches between lightThemeName and darkThemeName.
#pragma once

#import <Cocoa/Cocoa.h>

extern NSNotificationName const NppStylesChangedNotification;

@interface NppTheme : NSObject

+ (BOOL)isDark;
// Applies NSApp appearance and loads the matching theme file.
+ (void)applyMode;
// Loads a theme file (path) and notifies all views to restyle.
+ (void)switchToThemeAtPath:(NSString*)path;
// Re-applies the current styles everywhere (after Style Configurator edits).
+ (void)notifyStylesChanged;

@end
