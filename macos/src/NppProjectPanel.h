// Project Panel 1-3.
#pragma once

#import <Cocoa/Cocoa.h>
#import "NppDock.h"

@class NppMainWindow;

@interface NppProjectPanel : NSObject <NppDockPanel, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
// `index` is 0, 1 or 2 (IDM_VIEW_PROJECT_PANEL_1 + index).
- (instancetype)initWithWindow:(NppMainWindow*)window index:(int)index;
@property (nonatomic, readonly) BOOL isDirty;
// Asks to save a modified workspace; NO when the user cancelled.
- (BOOL)checkIfNeedSave;
@end
