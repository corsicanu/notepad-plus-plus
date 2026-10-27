// Style Configurator: port of WinControls/ColourPicker/WordStyleDlg, laid
// out from upstream's IDD_STYLER_DLG. Edits apply live; "Save & Close"
// writes the theme file, "Cancel" reloads it.
#pragma once

#import <Cocoa/Cocoa.h>

@interface NppStyleConfigurator : NSObject

+ (instancetype)shared;
- (void)show;
// Selects a language section by name, e.g. "Global Styles" (Preferences "Go to settings").
- (void)goToSection:(NSString*)lexerDesc;

@end
