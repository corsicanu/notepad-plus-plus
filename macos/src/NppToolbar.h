// Main toolbar: buttons and icons from upstream's toolBarIcons[] and the
// ICON/BITMAP resources of Notepad_plus.rc (Fluent UI regular/filled,
// light/dark, and the standard bitmap set).
#pragma once

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, NppToolbarIconSet) {
	NppToolbarSmall = 0,     // Fluent UI: small (regular)
	NppToolbarLarge,         // Fluent UI: large (regular)
	NppToolbarSmall2,        // Fluent UI: small (filled)
	NppToolbarLarge2,        // Fluent UI: large (filled)
	NppToolbarStandard,      // Standard icons: small
};

@interface NppToolbar : NSView

// Called for every button press with its Notepad++ command ID.
@property (nonatomic, copy) void (^onCommand)(int cmd);
// Asked to refresh enabled / checked state of a command.
@property (nonatomic, copy) BOOL (^isEnabled)(int cmd);
@property (nonatomic, copy) BOOL (^isChecked)(int cmd);

@property (nonatomic) NppToolbarIconSet iconSet;

- (void)reloadIcons;
- (void)updateStates;
- (CGFloat)preferredHeight;

@end
