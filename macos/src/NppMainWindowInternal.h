// Shared state of NppMainWindow for its categories (NppCommands.mm, ...).
#pragma once

#import "NppMainWindow.h"
#import "NppBuffer.h"
#import "NppFinder.h"
#import "NppFindReplaceDlg.h"
#import "ScintillaView.h"

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
