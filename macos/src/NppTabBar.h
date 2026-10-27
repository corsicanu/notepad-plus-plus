// Document tab bar, drawn after PowerEditor's TabBarPlus: active tab with
// a coloured top stripe, saved/unsaved icon, per-tab close button.
#pragma once

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, NppTabState) {
	NppTabSaved,
	NppTabUnsaved,
	NppTabReadOnly,
};

@class NppTabBar;

// One tab as drawn by the bar.
@interface NppTabInfo : NSObject
@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy) NSString* tooltip;
@property (nonatomic) NppTabState state;
@property (nonatomic) BOOL pinned;
@property (nonatomic, strong) NSColor* color;   // individual tab colour, nil = none
@end

@protocol NppTabBarDelegate <NSObject>
- (void)tabBar:(NppTabBar*)tabBar didSelectTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar*)tabBar didRequestCloseTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar*)tabBar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)tabBarDidRequestNewTab:(NppTabBar*)tabBar;
- (NSMenu*)tabBar:(NppTabBar*)tabBar menuForTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar*)tabBar didRequestPinTabAtIndex:(NSInteger)index;
@end

@interface NppTabBar : NSView

@property (nonatomic, weak) id<NppTabBarDelegate> delegate;
@property (nonatomic) NSInteger selectedIndex;

- (void)setTabs:(NSArray<NppTabInfo*>*)tabs;

// TabBar options from config.xml (<GUIConfig name="TabBar">).
@property (nonatomic) BOOL showCloseButton;
@property (nonatomic) BOOL doubleClickCloses;
@property (nonatomic) BOOL lockDrag;
@property (nonatomic) BOOL drawTopBar;
@property (nonatomic) BOOL showPinButton;

@end
