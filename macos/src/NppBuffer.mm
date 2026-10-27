#import "NppBuffer.h"

#include "NppUpstream.h"
#include "NppSettings.h"
#include "EncodingMapper.h"
#include "uchardet.h"

namespace
{
	enum u78 { utf8NoBOM = 0, ascii7bits = 1, ascii8bits = 2 };

	// Port of Utf8_16_Read::utf8_7bits_8bits.
	u78 utf8_7bits_8bits(const unsigned char* sx, size_t len)
	{
		int rv = 1;
		int ASCII7only = 1;
		const unsigned char* endx = sx + len;
		while (sx < endx)
		{
			if (*sx == '\0')
			{
				ASCII7only = 0;
				rv = 0;
				break;
			}
			else if ((*sx & 0x80) == 0x0)
				++sx;
			else if ((*sx & (0x80 + 0x40)) == 0x80)
			{
				ASCII7only = 0;
				rv = 0;
				break;
			}
			else if ((*sx & (0x80 + 0x40 + 0x20)) == (0x80 + 0x40))
			{
				ASCII7only = 0;
				if (endx - sx < 2 || (sx[1] & (0x80 + 0x40)) != 0x80) { rv = 0; break; }
				sx += 2;
			}
			else if ((*sx & (0x80 + 0x40 + 0x20 + 0x10)) == (0x80 + 0x40 + 0x20))
			{
				ASCII7only = 0;
				if (endx - sx < 3 || (sx[1] & (0x80 + 0x40)) != 0x80 || (sx[2] & (0x80 + 0x40)) != 0x80) { rv = 0; break; }
				sx += 3;
			}
			else if ((*sx & (0x80 + 0x40 + 0x20 + 0x10 + 0x8)) == (0x80 + 0x40 + 0x20 + 0x10))
			{
				ASCII7only = 0;
				if (endx - sx < 4 || (sx[1] & (0x80 + 0x40)) != 0x80 || (sx[2] & (0x80 + 0x40)) != 0x80 || (sx[3] & (0x80 + 0x40)) != 0x80) { rv = 0; break; }
				sx += 4;
			}
			else
			{
				ASCII7only = 0;
				rv = 0;
				break;
			}
		}
		if (ASCII7only)
			return ascii7bits;
		if (rv)
			return utf8NoBOM;
		return ascii8bits;
	}

	// Rough stand-in for Win32 IsTextUnicode(IS_TEXT_UNICODE_STATISTICS) on "x\0x\0" data.
	bool looksLikeUtf16LE(const unsigned char* p, size_t len)
	{
		if (len < 2 || len % 2 != 0 || p[0] == 0 || p[1] != 0)
			return false;
		size_t zeroOdd = 0, n = std::min<size_t>(len, 4096);
		for (size_t i = 1; i < n; i += 2)
			if (p[i] == 0)
				++zeroOdd;
		return zeroOdd * 2 >= (n / 2) * 2 * 9 / 10;
	}

	// Port of Utf8_16_Read::determineEncoding (skip = BOM length).
	UniMode determineEncoding(const unsigned char* p, size_t len, size_t& skip)
	{
		skip = 0;
		if (len > 1 && p[0] == 0xFE && p[1] == 0xFF) { skip = 2; return uni16BE; }
		if (len > 1 && p[0] == 0xFF && p[1] == 0xFE) { skip = 2; return uni16LE; }
		if (len > 2 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) { skip = 3; return uniUTF8; }
		if (looksLikeUtf16LE(p, len))
			return uni16LE_NoBOM;
		u78 d = utf8_7bits_8bits(p, len);
		if (d == utf8NoBOM)
			return uniUTF8_NoBOM;
		if (d == ascii7bits)
			return uni7Bit;
		return uni8Bit;
	}

	// Port of FileManager::detectCodepage.
	int detectCodepage(const char* buf, size_t len)
	{
		int codepage = -1;
		uchardet_t ud = uchardet_new();
		uchardet_handle_data(ud, buf, len);
		uchardet_data_end(ud);
		const char* cs = uchardet_get_charset(ud);
		if (strcasecmp(cs, "TIS-620") != 0)
			codepage = EncodingMapper::getInstance().getEncodingFromString(cs);
		uchardet_delete(ud);
		return codepage;
	}

	NSStringEncoding nsEncodingForCodepage(int cp)
	{
		switch (cp)
		{
			case 51949: return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR);
			case 10007: return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingMacCyrillic);
			case 20866: return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingKOI8_R);
			case 21866: return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingKOI8_U);
			case 936: return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
		}
		CFStringEncoding cf = CFStringConvertWindowsCodepageToEncoding(cp);
		if (cf == kCFStringEncodingInvalidId)
			return NSWindowsCP1252StringEncoding;
		return CFStringConvertEncodingToNSStringEncoding(cf);
	}

	NppEOL detectEOL(const char* p, size_t len, NppEOL fallback)
	{
		for (size_t i = 0; i < len; ++i)
		{
			if (p[i] == '\r')
				return (i + 1 < len && p[i + 1] == '\n') ? NppEOLWindows : NppEOLMac;
			if (p[i] == '\n')
				return NppEOLUnix;
		}
		return fallback;
	}

	NSData* utf16ToUtf8(NSData* d, bool bigEndian)
	{
		NSString* s = [[NSString alloc] initWithData: d encoding: bigEndian ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding];
		return [s dataUsingEncoding: NSUTF8StringEncoding] ?: [NSData data];
	}
}

@implementation NppBuffer
{
	void* _document;
}

+ (int)ansiCodepage
{
	return 1252;
}

+ (NSData*)decode:(NSData*)bytes codepage:(int)cp
{
	if (cp == SC_CP_UTF8)
		return bytes;
	NSString* s = [[NSString alloc] initWithData: bytes encoding: nsEncodingForCodepage(cp)];
	if (!s)
		s = [[NSString alloc] initWithData: bytes encoding: NSISOLatin1StringEncoding];
	return [s dataUsingEncoding: NSUTF8StringEncoding] ?: [NSData data];
}

+ (NSData*)encode:(NSData*)utf8 codepage:(int)cp
{
	if (cp == SC_CP_UTF8)
		return utf8;
	NSString* s = [[NSString alloc] initWithData: utf8 encoding: NSUTF8StringEncoding] ?: @"";
	return [s dataUsingEncoding: nsEncodingForCodepage(cp) allowLossyConversion: YES] ?: [NSData data];
}

- (instancetype)initWithEditor:(ScintillaView*)editor
{
	if ((self = [super init]))
	{
		_document = reinterpret_cast<void*>([editor message: SCI_CREATEDOCUMENT wParam: 0 lParam: SC_DOCUMENTOPTION_DEFAULT]);
		const NppSettings& s = NppSettings::instance();
		_unicodeMode = s._newDocUnicodeMode;
		_encoding = -1;
		_eol = (NppEOL)s._newDocFormat;
		_lang = LangManager::instance().languageByType(s._newDocLang) ?: LangManager::instance().languageByName("normal");
		_untitledName = @"new 1";
	}
	return self;
}

- (void*)document
{
	return _document;
}

- (NSString*)displayName
{
	return _path ? _path.lastPathComponent : _untitledName;
}

- (void)releaseDocumentWithEditor:(ScintillaView*)editor
{
	if (_document)
	{
		[editor message: SCI_RELEASEDOCUMENT wParam: 0 lParam: reinterpret_cast<sptr_t>(_document)];
		_document = nullptr;
	}
}

- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error
{
	return [self loadFromPath: path editor: editor forcedEncoding: -1 error: error];
}

// Port of FileManager::loadFileData / copyFileContentToScintilla / resolveLoadedEncoding.
- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor forcedEncoding:(int)forced error:(NSError**)error
{
	NSData* data = [NSData dataWithContentsOfFile: path options: NSDataReadingMappedIfSafe error: error];
	if (!data)
		return NO;

	const NppSettings& settings = NppSettings::instance();
	const unsigned char* bytes = static_cast<const unsigned char*>(data.bytes);
	size_t len = data.length;

	int encoding = forced;
	size_t skip = 0;
	UniMode bomMode = determineEncoding(bytes, len, skip);
	bool hasBOM = bomMode == uniUTF8 || bomMode == uni16BE || bomMode == uni16LE;
	if (hasBOM)
		encoding = -1;
	else if (encoding == -1 && settings._detectEncoding)
		encoding = detectCodepage(static_cast<const char*>(data.bytes), std::min<size_t>(len, 1024 * 1024));

	NSData* utf8 = nil;
	UniMode um = bomMode;
	if (encoding != -1)
	{
		utf8 = [NppBuffer decode: data codepage: encoding];
		// resolveLoadedEncoding: a codepage (or UTF-8 indicator) means UTF-8 text inside.
		if (encoding == SC_CP_UTF8)
			encoding = -1;
		um = uniUTF8_NoBOM;
	}
	else
	{
		NSData* body = [data subdataWithRange: NSMakeRange(skip, len - skip)];
		switch (bomMode)
		{
			case uni16BE:
			case uni16BE_NoBOM:
				utf8 = utf16ToUtf8(body, true);
				break;
			case uni16LE:
			case uni16LE_NoBOM:
				utf8 = utf16ToUtf8(body, false);
				break;
			case uni8Bit:
				utf8 = [NppBuffer decode: body codepage: [NppBuffer ansiCodepage]];
				break;
			default:
				utf8 = body;
				break;
		}
		if (um == uni7Bit)
			um = settings._openAnsiAsUtf8 ? uniUTF8_NoBOM : uni8Bit;
	}

	// Empty files take the "new document" encoding when it is UTF-8 and ANSI files open as UTF-8.
	if (len == 0 && settings._newDocUnicodeMode == uniUTF8_NoBOM && settings._openAnsiAsUtf8)
		um = uniUTF8_NoBOM;

	const char* text = static_cast<const char*>(utf8.bytes);
	_eol = detectEOL(text, utf8.length, (NppEOL)settings._newDocFormat);

	[editor message: SCI_SETREADONLY wParam: 0];
	[editor message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
	[editor message: SCI_SETUNDOCOLLECTION wParam: 0];
	[editor message: SCI_CLEARALL];
	[editor message: SCI_ALLOCATE wParam: utf8.length];
	[editor message: SCI_APPENDTEXT wParam: utf8.length lParam: reinterpret_cast<sptr_t>(text)];
	[editor message: SCI_SETUNDOCOLLECTION wParam: 1];
	[editor message: SCI_EMPTYUNDOBUFFER];
	[editor message: SCI_SETSAVEPOINT];
	[editor message: SCI_SETEOLMODE wParam: _eol];
	[editor message: SCI_GOTOPOS wParam: 0];

	_unicodeMode = um;
	_encoding = encoding;
	_path = [path copy];
	_dirty = NO;
	_fileReadOnly = ![NSFileManager.defaultManager isWritableFileAtPath: path];
	_lang = LangManager::instance().languageForPath(path.fileSystemRepresentation);
	[self updateTimestamp];
	return YES;
}

- (NSData*)bytesForSavingFrom:(ScintillaView*)editor
{
	sptr_t len = [editor message: SCI_GETLENGTH];
	const char* raw = reinterpret_cast<const char*>([editor message: SCI_GETCHARACTERPOINTER]);
	NSData* text = [NSData dataWithBytes: raw length: len];

	if (_encoding != -1)
		return [NppBuffer encode: text codepage: _encoding];

	NSMutableData* out = [NSMutableData data];
	switch (_unicodeMode)
	{
		case uniUTF8:
			[out appendBytes: "\xEF\xBB\xBF" length: 3];
			[out appendData: text];
			break;
		case uni16BE:
		case uni16LE:
		case uni16BE_NoBOM:
		case uni16LE_NoBOM:
		{
			bool be = _unicodeMode == uni16BE || _unicodeMode == uni16BE_NoBOM;
			if (_unicodeMode == uni16BE || _unicodeMode == uni16LE)
				[out appendBytes: be ? "\xFE\xFF" : "\xFF\xFE" length: 2];
			NSString* s = [[NSString alloc] initWithData: text encoding: NSUTF8StringEncoding] ?: @"";
			[out appendData: [s dataUsingEncoding: be ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding]];
			break;
		}
		case uni8Bit:
		case uni7Bit:
			[out appendData: [NppBuffer encode: text codepage: [NppBuffer ansiCodepage]]];
			break;
		default:
			[out appendData: text];
			break;
	}
	return out;
}

- (BOOL)saveToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error
{
	if (![self writeCopyToPath: path editor: editor error: error])
		return NO;
	[editor message: SCI_SETSAVEPOINT];
	_path = [path copy];
	_dirty = NO;
	_fileReadOnly = NO;
	[self updateTimestamp];
	return YES;
}

- (BOOL)writeCopyToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error
{
	return [[self bytesForSavingFrom: editor] writeToFile: path options: NSDataWritingAtomic error: error];
}

- (void)reinterpretFromCodepage:(int)from toCodepage:(int)to editor:(ScintillaView*)editor
{
	if (from == to)
		return;
	sptr_t len = [editor message: SCI_GETLENGTH];
	const char* raw = reinterpret_cast<const char*>([editor message: SCI_GETCHARACTERPOINTER]);
	NSData* bytes = [NppBuffer encode: [NSData dataWithBytes: raw length: len] codepage: from];
	NSData* text = [NppBuffer decode: bytes codepage: to];
	BOOL modified = [editor message: SCI_GETMODIFY] != 0;
	[editor message: SCI_SETUNDOCOLLECTION wParam: 0];
	[editor message: SCI_CLEARALL];
	[editor message: SCI_APPENDTEXT wParam: text.length lParam: reinterpret_cast<sptr_t>(text.bytes)];
	[editor message: SCI_SETUNDOCOLLECTION wParam: 1];
	[editor message: SCI_EMPTYUNDOBUFFER];
	if (!modified)
		[editor message: SCI_SETSAVEPOINT];
}

#pragma mark - Disk state

- (NSDate*)diskModificationDate
{
	if (!_path)
		return nil;
	return [[NSFileManager.defaultManager attributesOfItemAtPath: _path error: nil] fileModificationDate];
}

- (void)updateTimestamp
{
	_lastModified = [self diskModificationDate];
}

- (BOOL)fileDeleted
{
	return _path && ![NSFileManager.defaultManager fileExistsAtPath: _path];
}

- (BOOL)fileChangedOnDisk
{
	NSDate* d = [self diskModificationDate];
	return d && _lastModified && ![d isEqualToDate: _lastModified];
}

@end
