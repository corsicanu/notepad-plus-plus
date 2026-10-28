// Character Panel rows from upstream asciiListView.cpp, compiled unchanged
// against a stand-in AsciiListView that collects the rows instead of
// filling a Win32 list view.

#import <Foundation/Foundation.h>

#include <windows.h>

#include <cwchar>
#include <string>
#include <vector>

#include "NppAsciiTable.h"

using namespace std;

namespace
{
	template <typename T, size_t N>
	constexpr size_t _countof(T (&)[N]) { return N; }

	// One single-byte character of a Windows codepage to UTF-16.
	int MultiByteToWideChar(unsigned codepage, unsigned, const char* src, int, wchar_t* dest, size_t destLen)
	{
		CFStringEncoding enc = CFStringConvertWindowsCodepageToEncoding(codepage ? codepage : 1252);
		if (enc == kCFStringEncodingInvalidId)
			enc = kCFStringEncodingWindowsLatin1;
		NSString* s = (__bridge_transfer NSString*)CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(src), strlen(src), enc, false);
		size_t i = 0;
		for (; s && i < s.length && i + 1 < destLen; ++i)
			dest[i] = [s characterAtIndex: i];
		dest[i] = 0;
		return static_cast<int>(i);
	}

	class AsciiListView
	{
	public:
		void setValues(int codepage = 0);
		wstring getAscii(unsigned char value);
		wstring getHtmlName(unsigned char value);
		int getHtmlNumber(unsigned char value);

		std::vector<std::vector<std::wstring>> _lines;
	private:
		int _codepage = 0;
		void addLine(const std::vector<std::wstring>& values) { _lines.push_back(values); }
	};

#include "AsciiListView.inc"
}

std::vector<std::vector<std::wstring>> nppAsciiTable(int codepage)
{
	AsciiListView v;
	v.setValues(codepage);
	return v._lines;
}
