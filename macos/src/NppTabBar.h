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

@protocol NppTabBarDelegate <NSObject>
- (void)tabBar:(NppTabBar*)tabBar didSelectTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar*)tabBar didRequestCloseTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar*)tabBar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)tabBarDidRequestNewTab:(NppTabBar*)tabBar;
@end

@interface NppTabBar : NSView

@property (nonatomic, weak) id<NppTabBarDelegate> delegate;
@property (nonatomic) NSInteger selectedIndex;

- (void)setTabs:(NSArray<NSString*>*)titles states:(NSArray<NSNumber*>*)states tooltips:(NSArray<NSString*>*)tooltips;

@end
