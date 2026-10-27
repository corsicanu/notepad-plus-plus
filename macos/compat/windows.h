// Minimal stand-in for <windows.h> so upstream sources that include it
// for a few CRT helpers compile on macOS without being modified.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>

#ifndef __OBJC__
typedef int BOOL; // Objective-C has its own BOOL
#endif
typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef uint32_t DWORD;
typedef unsigned int UINT;
typedef int32_t LONG;
typedef DWORD COLORREF;
typedef intptr_t INT_PTR;
typedef intptr_t LPARAM;
typedef uintptr_t WPARAM;
typedef intptr_t LRESULT;
typedef void* HWND;
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* HMENU;
typedef void* HBITMAP;
typedef void* HICON;
typedef void* HFONT;
typedef void* HBRUSH;
typedef uint32_t ULONG;
typedef int INT;
typedef long long LONGLONG;
typedef const wchar_t* LPCWSTR;
typedef wchar_t* LPWSTR;
typedef const char* LPCSTR;
typedef char* LPSTR;
typedef void* LPVOID;
typedef wchar_t WCHAR;
typedef wchar_t TCHAR;

#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif
#ifndef MAX_PATH
#define MAX_PATH 1024
#endif

#define RGB(r, g, b) ((COLORREF)(((BYTE)(r) | ((WORD)((BYTE)(g)) << 8)) | (((DWORD)(BYTE)(b)) << 16)))
#define GetRValue(rgb) ((BYTE)(rgb))
#define GetGValue(rgb) ((BYTE)(((WORD)(rgb)) >> 8))
#define GetBValue(rgb) ((BYTE)((rgb) >> 16))
#define LOWORD(l) ((WORD)(((uintptr_t)(l)) & 0xffff))
#define HIWORD(l) ((WORD)((((uintptr_t)(l)) >> 16) & 0xffff))

#define WM_USER 0x0400

// Dialog result / standard control IDs (winuser.h).
#define IDOK 1
#define IDCANCEL 2
#define IDABORT 3
#define IDRETRY 4
#define IDIGNORE 5
#define IDYES 6
#define IDNO 7

// Virtual-key codes used by Notepad++'s shortcut tables.
#define VK_NULL 0x00
#define VK_BACK 0x08
#define VK_TAB 0x09
#define VK_RETURN 0x0D
#define VK_ESCAPE 0x1B
#define VK_SPACE 0x20
#define VK_PRIOR 0x21
#define VK_NEXT 0x22
#define VK_END 0x23
#define VK_HOME 0x24
#define VK_LEFT 0x25
#define VK_UP 0x26
#define VK_RIGHT 0x27
#define VK_DOWN 0x28
#define VK_INSERT 0x2D
#define VK_DELETE 0x2E
#define VK_0 0x30
#define VK_1 0x31
#define VK_2 0x32
#define VK_3 0x33
#define VK_4 0x34
#define VK_5 0x35
#define VK_6 0x36
#define VK_7 0x37
#define VK_8 0x38
#define VK_9 0x39
#define VK_A 0x41
#define VK_B 0x42
#define VK_C 0x43
#define VK_D 0x44
#define VK_E 0x45
#define VK_F 0x46
#define VK_G 0x47
#define VK_H 0x48
#define VK_I 0x49
#define VK_J 0x4A
#define VK_K 0x4B
#define VK_L 0x4C
#define VK_M 0x4D
#define VK_N 0x4E
#define VK_O 0x4F
#define VK_P 0x50
#define VK_Q 0x51
#define VK_R 0x52
#define VK_S 0x53
#define VK_T 0x54
#define VK_U 0x55
#define VK_V 0x56
#define VK_W 0x57
#define VK_X 0x58
#define VK_Y 0x59
#define VK_Z 0x5A
#define VK_NUMPAD0 0x60
#define VK_NUMPAD1 0x61
#define VK_NUMPAD2 0x62
#define VK_NUMPAD3 0x63
#define VK_NUMPAD4 0x64
#define VK_NUMPAD5 0x65
#define VK_NUMPAD6 0x66
#define VK_NUMPAD7 0x67
#define VK_NUMPAD8 0x68
#define VK_NUMPAD9 0x69
#define VK_DECIMAL 0x6E
#define VK_CLEAR 0x0C
#define VK_PAUSE 0x13
#define VK_CAPITAL 0x14
#define VK_SNAPSHOT 0x2C
#define VK_APPS 0x5D
#define VK_SCROLL 0x91
#define VK_NUMLOCK 0x90
#define VK_MULTIPLY 0x6A
#define VK_ADD 0x6B
#define VK_SUBTRACT 0x6D
#define VK_DIVIDE 0x6F
#define VK_F1 0x70
#define VK_F2 0x71
#define VK_F3 0x72
#define VK_F4 0x73
#define VK_F5 0x74
#define VK_F6 0x75
#define VK_F7 0x76
#define VK_F8 0x77
#define VK_F9 0x78
#define VK_F10 0x79
#define VK_F11 0x7A
#define VK_F12 0x7B
#define VK_OEM_1 0xBA
#define VK_OEM_PLUS 0xBB
#define VK_OEM_COMMA 0xBC
#define VK_OEM_MINUS 0xBD
#define VK_OEM_PERIOD 0xBE
#define VK_OEM_2 0xBF
#define VK_OEM_3 0xC0
#define VK_OEM_4 0xDB
#define VK_OEM_5 0xDC
#define VK_OEM_6 0xDD
#define VK_OEM_7 0xDE
#define VK_OEM_102 0xE2

inline int _stricmp(const char* a, const char* b) { return strcasecmp(a, b); }
inline int _strnicmp(const char* a, const char* b, size_t n) { return strncasecmp(a, b, n); }

inline char* _itoa(int value, char* buffer, int radix)
{
	if (radix == 10)
		std::snprintf(buffer, 33, "%d", value);
	else if (radix == 16)
		std::snprintf(buffer, 33, "%x", value);
	else if (radix == 8)
		std::snprintf(buffer, 33, "%o", value);
	else
	{
		char tmp[33];
		unsigned int v = static_cast<unsigned int>(value);
		int i = 0;
		do { tmp[i++] = "0123456789abcdefghijklmnopqrstuvwxyz"[v % radix]; v /= radix; } while (v && i < 32);
		int j = 0;
		while (i) buffer[j++] = tmp[--i];
		buffer[j] = '\0';
	}
	return buffer;
}
