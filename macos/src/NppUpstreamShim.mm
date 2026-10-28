// Definitions behind compat/shim/: what the upstream sources compiled
// against the shim headers need from the app.

#import <Foundation/Foundation.h>

#include "../compat/shim/ScintillaEditView.h"
#include "../compat/shim/Common.h"

LanguageNameInfo ScintillaEditView::_langNameInfoArray[L_EXTERNAL + 1] = {
#include "LangNameInfo.inc"
};

std::wstring string2wstring(const std::string& rString, unsigned int)
{
	NSString* s = [[NSString alloc] initWithBytes: rString.data() length: rString.size() encoding: NSUTF8StringEncoding] ?: @"";
	NSData* d = [s dataUsingEncoding: NSUTF32LittleEndianStringEncoding];
	return std::wstring(static_cast<const wchar_t*>(d.bytes), d.length / sizeof(wchar_t));
}

std::string wstring2string(const std::wstring& rwString, unsigned int)
{
	NSString* s = [[NSString alloc] initWithBytes: rwString.data() length: rwString.size() * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding] ?: @"";
	return s.UTF8String ?: "";
}
