// Incremental search bar: port of FindIncrementDlg, laid out from
// IDD_INCREMENT_FIND in upstream's FindReplaceDlg.rc.
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

#include "NppSearchEngine.h"

@interface NppIncrementalFind : NSObject

@property (nonatomic, readonly) NSView* view;
@property (nonatomic, copy) void (^onClose)(void);

- (instancetype)initWithEngine:(SearchEngine*)engine editor:(ScintillaView* (^)(void))editor;
- (void)focus;
- (void)searchNext:(BOOL)forward;

@end
