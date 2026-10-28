// Shared state of NppMainWindow for its categories (NppCommands.mm, ...).
#pragma once

#import "NppMainWindow.h"
#import "NppBuffer.h"
#import "NppFinder.h"
#import "NppFindReplaceDlg.h"
#import "NppDock.h"
#import "ScintillaView.h"

#include <string>

// Margins and markers, as in ScintillaEditView.
enum
{
	MARGIN_LINENUMBER = 0,
	MARGIN_SYMBOL = 1,
	MARGIN_CHANGEHISTORY = 2,
	MARGIN_FOLD = 3,
};

@interface NppMainWindow () <NppFindHost, NppFinderDelegate>

@property (nonatomic, readonly) ScintillaView* editor;
@property (nonatomic, readonly) NSMutableArray<NppBuffer*>* buffers;
@property (nonatomic, readonly) NSInteger currentIndex;
@property (nonatomic, readonly) NppFindReplaceDlg* findReplaceDlg;
@property (nonatomic) BOOL wordWrap;

- (NppBuffer*)currentBuffer;
- (void)activateBuffer:(NSInteger)index;
- (void)newDocument;
- (void)openDocument;
- (void)closeBufferAtIndex:(NSInteger)index force:(BOOL)force;
- (BOOL)saveBuffer:(NppBuffer*)b as:(BOOL)saveAs;
- (BOOL)saveCopyOf:(NppBuffer*)b;
- (BOOL)confirmCloseBuffers:(NSArray<NppBuffer*>*)list;
- (void)reloadCurrent;
- (void)renameCurrent;
- (void)deleteCurrentFile;
- (void)restoreLastClosedFile;

- (void)refreshTabs;
- (void)updateTitle;
- (void)updateStatusBar;
- (void)updateLineNumberMargin;
- (void)applyLanguage:(NppBuffer*)b;

- (void)toggleBookmarkAtLine:(long)line;
- (void)goToLineDialog;

- (void)showIncrementalFind;
- (void)hideIncrementalFind;

- (NppFinder*)showFinder;
- (void)hideFinder;
- (BOOL)finderVisible;
- (NSString*)selectedTextOrWord:(BOOL)expandToWord;

- (void)saveCurrentViewState;

// Main / sub view (Notepad++'s two edit views).
- (void)sendCurrentToOtherView:(BOOL)clone;
- (void)switchToPane:(int)i;
- (BOOL)otherViewVisible;
- (int)activeView;
- (void)setSyncScroll:(BOOL)vertical on:(BOOL)on;
- (BOOL)syncScroll:(BOOL)vertical;
- (void)loadPane:(int)i;
- (void)showPane:(int)i;
- (BOOL)paneVisible:(int)i;
- (NSArray<NppBuffer*>*)subViewBuffers;
- (NSArray<NppBuffer*>*)allBuffers;
- (BOOL)revealBuffer:(NppBuffer*)b;
- (void)closeAllForced;
- (void)refreshAllTabs;
- (void)hidePane:(int)i;
- (void)togglePinCurrent;
- (void)setCurrentTabColor:(int)color;
- (void)moveCurrentTabTo:(NSInteger)to;
- (NSArray<ScintillaView*>*)allEditors;

// Docking panels.
@property (nonatomic, readonly) NppDockManager* dock;
- (NSArray<NppBuffer*>*)buffersOfView:(int)view;
- (void)activateBuffer:(NppBuffer*)b inView:(int)view;
- (NSImage*)tabStateImageFor:(NppBuffer*)b;
- (NSMenu*)documentListContextMenu;
- (void)postDocumentsChanged;
- (void)findInFilesInDirectory:(NSString*)dir;

- (NppBuffer*)openSessionFile:(NSString*)file backup:(NSString*)backup encoding:(int)encoding;

@end

@interface NppMainWindow (Session)
- (void)applySettingsToEditor:(ScintillaView*)e;
- (void)captureEditorSettings;
- (void)restoreWindowFrame;
- (void)startSnapshotTimer;
- (void)saveSessionToPath:(NSString*)path withBackups:(BOOL)withBackups;
- (void)loadSessionFromPath:(NSString*)path;
- (void)checkModifiedFiles;
- (void)snapshotTick:(NSTimer*)t;
@end

// Macros and Run menu (NppMacros.mm).
@interface NppMainWindow (Macros)
- (void)macroRecordNotification:(SCNotification*)n;
- (void)saveCurrentMacroNamed:(NSString*)name;
- (void)runUserCommand:(const std::string&)cmd;
- (BOOL)isRecordingMacro;
- (BOOL)isPlayingBackMacro;
@end

// Typing helpers (NppAutoComplete.mm).
@interface NppMainWindow (AutoComplete)
- (void)charAdded:(int)ch;
- (void)callTipClicked:(int)direction;
- (void)autoCompletionSelected:(SCNotification*)n;
@end
