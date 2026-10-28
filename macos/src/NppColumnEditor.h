// Column / Multi-Selection Editor: port of ScintillaComponent/columnEditor,
// laid out from upstream's IDD_COLUMNEDIT.
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

@interface NppColumnEditor : NSObject
- (instancetype)initWithEditor:(ScintillaView* (^)(void))editor;
- (void)show;
@end
