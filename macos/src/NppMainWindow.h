// The Notepad++ main window: tab bar, one Scintilla editor that swaps
// documents per tab (as PowerEditor's ScintillaEditView does), status bar.
#pragma once

#import <Cocoa/Cocoa.h>

@interface NppMainWindow : NSWindowController

+ (NSArray<NSString*>*)recentFiles;
+ (void)clearRecentFiles;

- (void)newDocument:(id)sender;
- (void)openPaths:(NSArray<NSString*>*)paths;

// YES when every dirty buffer was saved or discarded by the user.
- (BOOL)confirmCloseAll;

@end
