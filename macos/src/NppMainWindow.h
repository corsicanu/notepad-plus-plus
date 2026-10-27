// The Notepad++ main window: tab bar, one Scintilla editor that swaps
// documents per tab (as PowerEditor's ScintillaEditView does), dockable
// panels and the status bar. Menu commands arrive as Notepad++ command
// IDs through -nppCommand: (see NppCommands.mm).
#pragma once

#import <Cocoa/Cocoa.h>

@interface NppMainWindow : NSWindowController

+ (NSArray<NSString*>*)recentFiles;
+ (void)clearRecentFiles;

- (void)openPaths:(NSArray<NSString*>*)paths;

// Command-line test hooks driving the Find dialog (see AppDelegate).
- (void)runFindTestHook:(NSString*)key value:(NSString*)value;

// YES when every dirty buffer was saved or discarded by the user.
- (BOOL)confirmCloseAll;

@end

// NppCommands.mm
@interface NppMainWindow (Commands)
// Runs a Notepad++ command (IDM_*); returns NO if the command isn't ported yet.
- (BOOL)runCommand:(int)cmd;
- (void)nppCommand:(id)sender;
@end

// NppSession.mm
@interface NppMainWindow (SessionAPI)
- (void)saveSessionToPath:(NSString*)path withBackups:(BOOL)withBackups;
- (void)loadSessionFromPath:(NSString*)path;
- (void)captureEditorSettings;
@end
