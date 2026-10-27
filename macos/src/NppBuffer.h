// One open document. Mirrors PowerEditor's Buffer: the text lives in a
// Scintilla document that is swapped into the single editor view.
#pragma once

#import <Cocoa/Cocoa.h>
#include "LangManager.h"

typedef NS_ENUM(NSInteger, NppEncoding) {
	NppEncodingANSI,       // Windows-1252, Notepad++'s "ANSI" on non-CJK systems
	NppEncodingUTF8,
	NppEncodingUTF8BOM,
	NppEncodingUTF16BE,
	NppEncodingUTF16LE,
};

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
@property (nonatomic) NppEncoding encoding;
@property (nonatomic) NppEOL eol;
@property (nonatomic) BOOL dirty;
@property (nonatomic) BOOL readOnly;

// Scintilla document (SCI_CREATEDOCUMENT); owned by this buffer.
@property (nonatomic, readonly) void* document;

// View state restored when the tab is activated again.
@property (nonatomic) long caretPos;
@property (nonatomic) long anchorPos;
@property (nonatomic) long firstVisibleLine;

+ (NSString*)encodingName:(NppEncoding)encoding;

- (instancetype)initWithEditor:(ScintillaView*)editor;

// Reads the file into this buffer's document. The document must be
// attached to `editor` while loading.
- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error;
- (BOOL)saveToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error;

// Drops the Scintilla document; call when the tab is closed.
- (void)releaseDocumentWithEditor:(ScintillaView*)editor;

@end
