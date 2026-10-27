// Minimal stand-in for <windows.h> so upstream sources that include it
// for a few CRT helpers compile on macOS without being modified.
#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>

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
