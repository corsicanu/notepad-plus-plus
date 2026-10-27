// Builds Cocoa windows from upstream DIALOGEX resources (*.rc), so every
// Notepad++ dialog keeps its original layout, texts and control IDs. The
// owner drives it like a Win32 dialog procedure: controls are looked up by
// ID and button clicks arrive as commands.
#pragma once

#import <Cocoa/Cocoa.h>

@class NppRcDialog;

// Returns YES when the command was handled. Unhandled IDOK/IDCANCEL close the dialog.
typedef BOOL (^NppRcCommandHandler)(NppRcDialog* dlg, int ctrlId);

@interface NppRcDialog : NSWindowController

// `rcFile` is the basename of an upstream .rc file ("findCharsInRange.rc"),
// `dialog` the resource name ("IDD_FINDCHARACTERS").
- (instancetype)initWithRC:(NSString*)rcFile dialog:(NSString*)dialog;

// Builds a dialog's controls into an existing view (Preferences pages, tabs).
+ (NSView*)viewFromRC:(NSString*)rcFile dialog:(NSString*)dialog owner:(NppRcDialog*)owner;

@property (nonatomic, copy) NppRcCommandHandler onCommand;
// Win32 notification code of the command being dispatched: 0 (BN_CLICKED /
// Enter in an edit) or EN_CHANGE for text edits.
@property (nonatomic, readonly) int lastNotification;
@property (nonatomic, readonly) NSString* caption;

- (NSView*)item:(int)ctrlId;
- (int)idOf:(NSString*)symbol;           // resolves names from the *_rc.h headers

- (BOOL)isChecked:(int)ctrlId;
- (void)setChecked:(int)ctrlId value:(BOOL)on;
- (NSString*)text:(int)ctrlId;
- (void)setText:(int)ctrlId value:(NSString*)text;
- (void)enable:(int)ctrlId value:(BOOL)on;
- (void)show:(int)ctrlId value:(BOOL)on;

- (void)showModeless;
- (NSModalResponse)runModal;              // ends with IDOK / IDCANCEL
- (void)endWith:(int)ctrlId;

// Resolves a #define from the bundled upstream headers (resource.h, *_rc.h).
+ (int)symbolValue:(NSString*)name;

@end
