// Docking panels hosted by NppDockManager.
#pragma once

#import <Cocoa/Cocoa.h>
#import "NppDock.h"

@class NppMainWindow;

// Posted whenever documents are opened, closed, renamed, moved or change state.
extern NSNotificationName const NppDocumentsChangedNotification;

@interface NppClipboardHistoryPanel : NSObject <NppDockPanel, NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithWindow:(NppMainWindow*)window;
@end

@interface NppCharacterPanel : NSObject <NppDockPanel, NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithWindow:(NppMainWindow*)window;
@end

@interface NppDocumentListPanel : NSObject <NppDockPanel, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
- (instancetype)initWithWindow:(NppMainWindow*)window;
@end
