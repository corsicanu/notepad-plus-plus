// Stand-in for PowerEditor's ScintillaEditView: the Scintilla calls that
// upstream's functionParser.cpp makes, through Scintilla's direct function.
#pragma once

#include <windows.h>

#include <string>
#include <string_view>

#include "Notepad_plus_msgs.h"
#include "Scintilla.h"

struct LanguageNameInfo {
	const wchar_t* _langName = nullptr;
	const wchar_t* _shortName = nullptr;
	const wchar_t* _longName = nullptr;
	LangType _langID = L_TEXT;
	const char* _lexerID = nullptr;
};

class ScintillaEditView
{
public:
	using DirectFn = sptr_t (*)(sptr_t, unsigned int, uptr_t, sptr_t);

	ScintillaEditView(DirectFn fn, sptr_t ptr) : _fn(fn), _ptr(ptr) {}

	sptr_t execute(unsigned int msg, uptr_t wParam = 0, sptr_t lParam = 0) const
	{
		return _fn(_ptr, msg, wParam, lParam);
	}

	intptr_t searchInTarget(std::string_view text2Find, size_t fromPos, size_t toPos) const
	{
		execute(SCI_SETTARGETRANGE, fromPos, toPos);
		return execute(SCI_SEARCHINTARGET, text2Find.length(), reinterpret_cast<sptr_t>(text2Find.data()));
	}

	// Text of [start, end) into dest, truncated to destlen - 1 bytes.
	void getGenericText(char* dest, size_t destlen, size_t start, size_t end) const
	{
		if (end - start >= destlen)
			end = start + destlen - 1;
		Sci_TextRangeFull tr{{static_cast<Sci_Position>(start), static_cast<Sci_Position>(end)}, dest};
		execute(SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
	}

	size_t getCurrentDocLen() const
	{
		return execute(SCI_GETLENGTH);
	}

	static LanguageNameInfo _langNameInfoArray[L_EXTERNAL + 1];

private:
	DirectFn _fn;
	sptr_t _ptr;
};
