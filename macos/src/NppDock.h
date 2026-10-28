// Docking panels around the editor: the macOS counterpart of upstream's
// DockingManager. Each side holds a stack of panels shown one at a time,
// with a caption bar (title + close) and tabs at the bottom when a side
// has more than one panel, as in Notepad++.
#pragma once

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, NppDockSide) {
	NppDockLeft = 0,
	NppDockRight,
};

@protocol NppDockPanel <NSObject>
@property (nonatomic, readonly) NSString* title;
@property (nonatomic, readonly) NSView* view;
@optional
- (void)panelDidShow;
- (void)panelDidHide;
@end

@interface NppDockManager : NSObject

// `center` is the editor area; `container` replaces it in the layout.
- (instancetype)initWithCenter:(NSView*)center;
@property (nonatomic, readonly) NSSplitView* container;

// Panels are identified by their command ID (IDM_VIEW_FUNC_LIST, ...).
- (void)addPanel:(id<NppDockPanel>)panel forCommand:(int)cmd side:(NppDockSide)side;
- (id<NppDockPanel>)panelForCommand:(int)cmd;
- (BOOL)isPanelVisible:(int)cmd;
- (void)showPanel:(int)cmd;
- (void)hidePanel:(int)cmd;
- (void)togglePanel:(int)cmd;

// Commands of the panels currently shown (for config.xml).
- (NSArray<NSNumber*>*)visibleCommands;
- (NSArray<NSNumber*>*)allCommands;
- (NppDockSide)sideOfCommand:(int)cmd;
- (CGFloat)widthOfSide:(NppDockSide)side;
- (void)setWidth:(CGFloat)width ofSide:(NppDockSide)side;
- (NSInteger)selectedIndexOfSide:(NppDockSide)side;     // -1 when the side is empty

@end
