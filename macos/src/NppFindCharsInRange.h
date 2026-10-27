// "Find Characters in Range" dialog: port of WinControls/FindCharsInRange,
// laid out from upstream's findCharsInRange.rc.
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

@interface NppFindCharsInRange : NSObject

- (instancetype)initWithEditor:(ScintillaView* (^)(void))editorProvider;
- (void)show;

@end
