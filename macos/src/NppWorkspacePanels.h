// Document Map and Folder as Workspace panels.
#pragma once

#import <Cocoa/Cocoa.h>
#import "NppDock.h"

@class NppMainWindow;

@interface NppDocumentMapPanel : NSObject <NppDockPanel>
- (instancetype)initWithWindow:(NppMainWindow*)window;
// Re-marks the editor's visible zone (called on editor scroll / resize).
- (void)scrollMap;
- (void)reloadMap;
@end

@interface NppFolderAsWorkspacePanel : NSObject <NppDockPanel, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
- (instancetype)initWithWindow:(NppMainWindow*)window;
- (void)addRoot:(NSString*)path;
@end
