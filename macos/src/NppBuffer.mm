#import "NppBuffer.h"

#include "Scintilla.h"

@implementation NppBuffer
{
	void* _document;
}

+ (NSString*)encodingName:(NppEncoding)encoding
{
	switch (encoding)
	{
		case NppEncodingANSI: return @"ANSI";
		case NppEncodingUTF8: return @"UTF-8";
		case NppEncodingUTF8BOM: return @"UTF-8-BOM";
		case NppEncodingUTF16BE: return @"UTF-16 BE BOM";
		case NppEncodingUTF16LE: return @"UTF-16 LE BOM";
	}
	return nil;
}

- (instancetype)initWithEditor:(ScintillaView*)editor
{
	if ((self = [super init]))
	{
		_document = reinterpret_cast<void*>([editor message: SCI_CREATEDOCUMENT wParam: 0 lParam: SC_DOCUMENTOPTION_DEFAULT]);
		_encoding = NppEncodingUTF8;
		_eol = NppEOLUnix;
		_lang = LangManager::instance().languageByName("normal");
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

static BOOL isValidUTF8(const unsigned char* p, NSUInteger len)
{
	NSUInteger i = 0;
	while (i < len)
	{
		unsigned char c = p[i];
		int extra;
		if (c < 0x80) { ++i; continue; }
		else if ((c & 0xE0) == 0xC0 && c >= 0xC2) extra = 1;
		else if ((c & 0xF0) == 0xE0) extra = 2;
		else if ((c & 0xF8) == 0xF0 && c <= 0xF4) extra = 3;
		else return NO;
		for (int k = 1; k <= extra; ++k)
			if (i + k >= len || (p[i + k] & 0xC0) != 0x80)
				return NO;
		i += extra + 1;
	}
	return YES;
}

static NppEOL detectEOL(const char* p, size_t len)
{
	for (size_t i = 0; i < len; ++i)
	{
		if (p[i] == '\r')
			return (i + 1 < len && p[i + 1] == '\n') ? NppEOLWindows : NppEOLMac;
		if (p[i] == '\n')
			return NppEOLUnix;
	}
	// Notepad++ default for new documents on Windows is CRLF; on macOS LF is the norm.
	return NppEOLUnix;
}

- (BOOL)loadFromPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error
{
	NSData* data = [NSData dataWithContentsOfFile: path options: 0 error: error];
	if (!data)
		return NO;

	const unsigned char* bytes = static_cast<const unsigned char*>(data.bytes);
	NSUInteger len = data.length;
	NSData* utf8 = nil;

	if (len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
	{
		_encoding = NppEncodingUTF8BOM;
		utf8 = [data subdataWithRange: NSMakeRange(3, len - 3)];
	}
	else if (len >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
	{
		_encoding = NppEncodingUTF16BE;
		NSString* s = [[NSString alloc] initWithData: [data subdataWithRange: NSMakeRange(2, len - 2)] encoding: NSUTF16BigEndianStringEncoding];
		utf8 = [s dataUsingEncoding: NSUTF8StringEncoding];
	}
	else if (len >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
	{
		_encoding = NppEncodingUTF16LE;
		NSString* s = [[NSString alloc] initWithData: [data subdataWithRange: NSMakeRange(2, len - 2)] encoding: NSUTF16LittleEndianStringEncoding];
		utf8 = [s dataUsingEncoding: NSUTF8StringEncoding];
	}
	else if (isValidUTF8(bytes, len))
	{
		_encoding = NppEncodingUTF8;
		utf8 = data;
	}
	else
	{
		_encoding = NppEncodingANSI;
		NSString* s = [[NSString alloc] initWithData: data encoding: NSWindowsCP1252StringEncoding];
		if (!s)
			s = [[NSString alloc] initWithData: data encoding: NSISOLatin1StringEncoding];
		utf8 = [s dataUsingEncoding: NSUTF8StringEncoding];
	}
	if (!utf8)
		utf8 = [NSData data];

	const char* text = static_cast<const char*>(utf8.bytes);
	_eol = detectEOL(text, utf8.length);

	[editor message: SCI_SETCODEPAGE wParam: SC_CP_UTF8];
	[editor message: SCI_SETUNDOCOLLECTION wParam: 0];
	[editor message: SCI_CLEARALL];
	[editor message: SCI_APPENDTEXT wParam: utf8.length lParam: reinterpret_cast<sptr_t>(text)];
	[editor message: SCI_SETUNDOCOLLECTION wParam: 1];
	[editor message: SCI_EMPTYUNDOBUFFER];
	[editor message: SCI_SETSAVEPOINT];
	[editor message: SCI_SETEOLMODE wParam: _eol];
	[editor message: SCI_GOTOPOS wParam: 0];

	_path = [path copy];
	_dirty = NO;
	_readOnly = ![[NSFileManager defaultManager] isWritableFileAtPath: path];
	_lang = LangManager::instance().languageForPath(path.fileSystemRepresentation);
	return YES;
}

- (BOOL)saveToPath:(NSString*)path editor:(ScintillaView*)editor error:(NSError**)error
{
	sptr_t len = [editor message: SCI_GETLENGTH];
	std::string text(len, '\0');
	[editor message: SCI_GETTEXT wParam: len + 1 lParam: reinterpret_cast<sptr_t>(text.data())];

	NSMutableData* out = [NSMutableData data];
	NSString* str = nil;
	switch (_encoding)
	{
		case NppEncodingUTF8BOM:
			[out appendBytes: "\xEF\xBB\xBF" length: 3];
			[[fallthrough]];
		case NppEncodingUTF8:
			[out appendBytes: text.data() length: text.size()];
			break;
		case NppEncodingUTF16BE:
		case NppEncodingUTF16LE:
		{
			BOOL be = _encoding == NppEncodingUTF16BE;
			[out appendBytes: be ? "\xFE\xFF" : "\xFF\xFE" length: 2];
			str = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
			[out appendData: [str dataUsingEncoding: be ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding]];
			break;
		}
		case NppEncodingANSI:
			str = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
			[out appendData: [str dataUsingEncoding: NSWindowsCP1252StringEncoding allowLossyConversion: YES]];
			break;
	}

	if (![out writeToFile: path options: NSDataWritingAtomic error: error])
		return NO;

	[editor message: SCI_SETSAVEPOINT];
	_path = [path copy];
	_dirty = NO;
	_readOnly = NO;
	return YES;
}

@end
