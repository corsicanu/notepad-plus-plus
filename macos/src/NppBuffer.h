// One open document. Mirrors PowerEditor's Buffer: the text lives in a
// Scintilla document (always UTF-8 here) that is swapped into an editor
// view; `unicodeMode` + `encoding` say how it maps to bytes on disk,
// exactly like Buffer::getUnicodeMode() / Buffer::getEncoding().
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#include "LangManager.h"

typedef NS_ENUM(NSInteger, NppEOL) {
	NppEOLWindows = 0,     // SC_EOL_CRLF
	NppEOLMac = 1,         // SC_EOL_CR
	NppEOLUnix = 2,        // SC_EOL_LF
};

@interface NppBuffer : NSObject

@property (nonatomic, copy) NSString* path;
@property (nonatomic, copy) NSString* untitledName;     // "new 1"
@property (nonatomic, readonly) NSString* displayName;
@property (nonatomic) const NppLang* lang;
@property (nonatomic) int unicodeMode;                  // UniMode (NppConstants.h)
@property (nonatomic) int encoding;                     // Windows codepage, -1 when unicodeMode decides
@property (nonatomic) NppEOL eol;
@property (nonatomic) BOOL dirty;
@property (nonatomic) BOOL readOnly;                    // Notepad++ "Read-Only" flag
@property (nonatomic) BOOL fileReadOnly;                // file is not writable
@property (nonatomic, copy) NSDate* lastModified;       // disk timestamp at load/save
@property (nonatomic, copy) NSString* backupPath;       // snapshot backup of unsaved changes
@property (nonatomic) BOOL pinned;                      // pinned tab
@property (nonatomic) int tabColor;                     // individual tab colour 0..4, -1 none

// Scintilla document (SCI_CREATEDOCUMENT); owned by this buffer.
@property (nonatomic, readonly) void* document;

// View state restored when the tab is activated again.
@property (nonatomic) long caretPos;
@property (nonatomic) long anchorPos;
@property (nonatomic) long firstVisibleLine;

// "ANSI" codepage: the Windows codepage used for uni8Bit documents.
+ (int)ansiCodepage;
// Codepage <-> bytes, using macOS converters for Windows codepages.
+ (NSData*)decode:(NSData*)bytes codepage:(int)cp;          // -> UTF-8
+ (NSData*)encode:(NSData*)utf8 codepage:(int)cp;           // UTF-8 ->

- (instancetype)initWithEditor:(ScintillaView*)editor;

// Reads the file into this buffer's document (attached to `editor`).
// `forcedEncoding`: -1 detects (BOM, uchardet, UTF-8 test), otherwise a codepage.
- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error;
- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor forcedEncoding:(int)encoding error:(NSError**)error;

// Encodes the text for disk (BOM, UTF-16 or codepage conversion, EOLs as in the text).
- (NSData*)bytesForSavingFrom:(ScintillaView*)editor;
- (BOOL)saveToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error;
- (BOOL)writeCopyToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error;

// Re-reads the current text as if its bytes were in another encoding
// ("Encode in ..."): text -> bytes(from) -> text(to).
- (void)reinterpretFromCodepage:(int)from toCodepage:(int)to editor:(ScintillaView*)editor;

// Disk state for change detection.
- (BOOL)fileChangedOnDisk;
- (BOOL)fileDeleted;
- (void)updateTimestamp;

- (void)releaseDocumentWithEditor:(ScintillaView*)editor;

@end
