// Find / Replace / Find in Files / Mark dialog: port of PowerEditor's
// FindReplaceDlg (UI + command handling). The search work itself is in
// NppSearchEngine.
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

#include "NppSearchEngine.h"

@class NppFinder;

typedef NS_ENUM(NSInteger, NppFindDialogType) {
	NppFindDialogFind = 0,
	NppFindDialogReplace,
	NppFindDialogFindInFiles,
	NppFindDialogMark,
};

// What the dialog needs from the main window.
@protocol NppFindHost <NSObject>
- (ScintillaView*)currentEditor;
- (BOOL)currentDocumentIsReadOnly;
- (NSString*)currentDocumentPath;       // nil for untitled
- (NSString*)currentDocumentName;
// Runs `block` with every open document attached to a view; `modified` must
// be set when the block changed the text.
- (void)forEachOpenDocument:(void (^)(ScintillaView* view, NSString* name, BOOL readOnly, BOOL* modified))block;
// Runs `block` on a file's text (open buffer if already open, else loaded from disk).
// Saves the file when `modified` is set and it wasn't open.
- (BOOL)withFile:(NSString*)path run:(void (^)(ScintillaView* view, BOOL* modified))block;
- (NppFinder*)showFinder;
- (void)documentsModifiedByReplace;
@end

@interface NppFindReplaceDlg : NSWindowController

@property (nonatomic, weak) id<NppFindHost> host;
@property (nonatomic, readonly) SearchEngine& engine;

- (void)showDialog:(NppFindDialogType)type;

// Search menu commands that don't need the dialog visible.
- (void)findNext:(BOOL)forward;                     // F3 / Shift+F3
- (void)selectAndFindNext:(BOOL)forward;            // Ctrl+F3
- (void)volatileFindNext:(BOOL)forward;             // Ctrl+Alt+F3
- (FindOption)currentOptions;

// Presses a dialog button by its FindReplaceDlg_rc.h ID (IDOK, IDCCOUNTALL,
// IDC_FINDALL_CURRENTFILE, IDREPLACEALL, IDCMARKALL, ...).
- (void)execDialogCommand:(int)idc;
- (void)setDirectory:(NSString*)dir filters:(NSString*)filters;
- (void)setReplaceText:(NSString*)text;
- (NSString*)findText;
- (void)setFindText:(NSString*)text;

@end
