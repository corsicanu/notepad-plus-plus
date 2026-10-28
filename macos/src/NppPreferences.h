// Preferences dialog: port of WinControls/Preference/preferenceDlg. The box
// and every page come from upstream's preference.rc (and regExtDlg.rc);
// controls are bound to NppSettings and changes apply immediately.
#pragma once

#import <Cocoa/Cocoa.h>

extern NSNotificationName const NppSettingsChangedNotification;

@interface NppPreferences : NSObject

+ (instancetype)shared;
- (void)show;
- (void)showPage:(NSString*)internalName;   // "Global", "Toolbar", ... (localization keys)

@end
