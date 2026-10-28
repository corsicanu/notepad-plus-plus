// Function List panel.
#pragma once

#import <Cocoa/Cocoa.h>
#import "NppDock.h"

@class NppMainWindow;

@interface NppFunctionListPanel : NSObject <NppDockPanel, NSOutlineViewDataSource, NSOutlineViewDelegate>
- (instancetype)initWithWindow:(NppMainWindow*)window;
- (void)reload;
// Selects the function containing the caret (called on caret moves).
- (void)markEntry;
@end
