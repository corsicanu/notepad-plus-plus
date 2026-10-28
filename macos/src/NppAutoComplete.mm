// Typing helpers of the main window: SCN_CHARADDED handling (auto-indent,
// auto-insert of matched pairs, auto-completion, call tips), as in
// Notepad_plus::maintainIndentation and NppNotification.cpp.

#import "NppMainWindowInternal.h"
#import "NppAutoCompletion.h"

#include "LangManager.h"
#include "NppSettings.h"
#include "NppUpstream.h"

#include <memory>
#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	// _autoCompleteMain / _autoCompleteSub: one per editor view.
	std::unordered_map<const void*, std::unique_ptr<NppAutoCompletion>>& completions()
	{
		static std::unordered_map<const void*, std::unique_ptr<NppAutoCompletion>> m;
		return m;
	}

	NppAutoCompletionSettings autocSettings()
	{
		const NppSettings& s = NppSettings::instance();
		NppAutoCompletionSettings a;
		a._autocStatus = static_cast<NppAutoCompletionSettings::AutocStatus>(std::clamp(s._autoCAction, 0, 3));
		a._autocFromLen = std::clamp(s._autoCFromNbChar, 1, 9);
		a._autocIgnoreNumbers = s._autoCIgnoreNumbers;
		a._autocBrief = s._autoCBrief;
		a._funcParams = s._funcParams;
		return a;
	}

	NppMatchedPairConf matchedPairConf()
	{
		const NppSettings& s = NppSettings::instance();
		NppMatchedPairConf c;
		c._matchedPairs = s._matchedPairs;
		c._doHtmlXmlTag = s._insertHtmlXmlTag;
		c._doParentheses = s._insertParentheses;
		c._doBrackets = s._insertBrackets;
		c._doCurlyBrackets = s._insertCurlyBrackets;
		c._doQuotes = s._insertQuotes;
		c._doDoubleQuotes = s._insertDoubleQuotes;
		return c;
	}

	// ScintillaEditView::setLineIndent: keeps the selection in place.
	void setLineIndent(ScintillaView* v, intptr_t line, intptr_t indent)
	{
		if (indent < 0)
			return;
		size_t nbSelections = sci(v, SCI_GETSELECTIONS);
		auto shift = [](intptr_t pos, intptr_t before, intptr_t after) {
			intptr_t diff = after - before;
			if (after > before)
				return pos >= before ? pos + diff : pos;
			if (after < before && pos >= after)
				return pos >= before ? pos + diff : after;
			return pos;
		};
		if (nbSelections == 1)
		{
			intptr_t selStart = sci(v, SCI_GETSELECTIONSTART), selEnd = sci(v, SCI_GETSELECTIONEND);
			intptr_t posBefore = sci(v, SCI_GETLINEINDENTPOSITION, line);
			sci(v, SCI_SETLINEINDENTATION, line, indent);
			intptr_t posAfter = sci(v, SCI_GETLINEINDENTPOSITION, line);
			sci(v, SCI_SETSEL, shift(selStart, posBefore, posAfter), shift(selEnd, posBefore, posAfter));
			return;
		}
		sci(v, SCI_BEGINUNDOACTION);
		for (size_t i = 0; i < nbSelections; ++i)
		{
			intptr_t posStart = sci(v, SCI_GETSELECTIONNSTART, i);
			intptr_t posEnd = sci(v, SCI_GETSELECTIONNEND, i);
			intptr_t l = sci(v, SCI_LINEFROMPOSITION, posStart);
			intptr_t posBefore = sci(v, SCI_GETLINEINDENTPOSITION, l);
			sci(v, SCI_SETLINEINDENTATION, l, indent);
			intptr_t posAfter = sci(v, SCI_GETLINEINDENTPOSITION, l);
			sci(v, SCI_SETSELECTIONNSTART, i, shift(posStart, posBefore, posAfter));
			sci(v, SCI_SETSELECTIONNEND, i, shift(posEnd, posBefore, posAfter));
		}
		sci(v, SCI_ENDUNDOACTION);
	}

	intptr_t lineLength(ScintillaView* v, intptr_t line)
	{
		return sci(v, SCI_GETLINEENDPOSITION, line) - sci(v, SCI_POSITIONFROMLINE, line);
	}

	bool searchWholeLine(ScintillaView* v, intptr_t line, const char* expr)
	{
		auto startPos = sci(v, SCI_POSITIONFROMLINE, line);
		auto endPos = sci(v, SCI_GETLINEENDPOSITION, line);
		sci(v, SCI_SETSEARCHFLAGS, SCFIND_REGEXP | SCFIND_POSIX);
		sci(v, SCI_SETTARGETRANGE, startPos, endPos);
		auto posFound = sci(v, SCI_SEARCHINTARGET, strlen(expr), reinterpret_cast<sptr_t>(expr));
		return posFound >= 0 && sci(v, SCI_GETTARGETEND) == endPos;
	}

	// Notepad_plus::isConditionExprLine
	bool isConditionExprLine(ScintillaView* v, intptr_t lineNumber)
	{
		if (lineNumber < 0 || lineNumber > sci(v, SCI_GETLINECOUNT))
			return false;
		return searchWholeLine(v, lineNumber, "((else[ \t]+)?if|for|while)[ \t]*[(].*[)][ \t]*|else[ \t]*");
	}

	// Notepad_plus::findMachedBracePos (backward search only, as upstream).
	intptr_t findMatchedBracePos(ScintillaView* v, intptr_t startPos, intptr_t endPos, char targetSymbol, char matchedSymbol)
	{
		if (startPos == endPos || startPos < endPos)
			return -1;
		int balance = 0;
		for (intptr_t i = startPos; i >= endPos; --i)
		{
			char aChar = static_cast<char>(sci(v, SCI_GETCHARAT, i));
			if (aChar == targetSymbol)
			{
				if (balance == 0)
					return i;
				--balance;
			}
			else if (aChar == matchedSymbol)
				++balance;
		}
		return -1;
	}
}

@implementation NppMainWindow (AutoComplete)

+ (void)registerAutoCompleteCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	t[IDM_EDIT_AUTOCOMPLETE] = ^(NppMainWindow* w) { [w autoCompletion]->showApiComplete(); };
	t[IDM_EDIT_AUTOCOMPLETE_CURRENTFILE] = ^(NppMainWindow* w) { [w autoCompletion]->showWordComplete(true); };
	t[IDM_EDIT_FUNCCALLTIP] = ^(NppMainWindow* w) { [w autoCompletion]->showFunctionComplete(); };
	t[IDM_EDIT_FUNCCALLTIP_PREVIOUS] = ^(NppMainWindow* w) { [w autoCompletion]->callTipClick(1); };
	t[IDM_EDIT_FUNCCALLTIP_NEXT] = ^(NppMainWindow* w) { [w autoCompletion]->callTipClick(2); };
	t[IDM_EDIT_AUTOCOMPLETE_PATH] = ^(NppMainWindow* w) { [w autoCompletion]->showPathCompletion(); };
}

// The current view's AutoCompletion, set to the current document's language
// (autoCompletion/<lang>.xml, upstream's API files).
- (NppAutoCompletion*)autoCompletion
{
	ScintillaView* e = self.editor;
	auto& slot = completions()[(__bridge const void*)e];
	if (!slot)
		slot = std::make_unique<NppAutoCompletion>(e);
	const NppLang* lang = [self currentBuffer].lang;
	int type = lang ? LangManager::instance().langTypeOf(lang) : L_TEXT;
	std::string api = lang ? lang->name : "";
	if (api == "javascript.js")
		api = "javascript";
	if (type == L_TEXT)
		api.clear();
	slot->setLanguage(type, api);
	return slot.get();
}

// SCN_CHARADDED
- (void)charAdded:(int)ch
{
	if ([self isRecordingMacro] || [self isPlayingBackMacro])
		return;
	const NppSettings& s = NppSettings::instance();
	if (s._maintainIndent != 0)
		[self maintainIndentation: ch];

	NppAutoCompletion* autoC = [self autoCompletion];
	bool isColumnMode = sci(self.editor, SCI_GETSELECTIONS) > 1;
	NppMatchedPairConf pairs = matchedPairConf();
	if (pairs.hasAnyPairsPair() && !isColumnMode)
		autoC->insertMatchedChars(ch, pairs);
	autoC->update(ch, autocSettings());
}

// SCN_CALLTIPCLICK
- (void)callTipClicked:(int)direction
{
	[self autoCompletion]->callTipClick(direction);
}

// SCN_AUTOCSELECTION: ENTER / TAB may be excluded from inserting the item.
- (void)autoCompletionSelected:(SCNotification*)n
{
	const NppSettings& s = NppSettings::instance();
	if (s._autoCAction == 0)
		return;
	ScintillaView* v = self.editor;
	if (n->listCompletionMethod == SC_AC_NEWLINE && !s._autoCInsertWithEnter)
	{
		sci(v, SCI_AUTOCCANCEL);
		sci(v, SCI_NEWLINE);
	}
	if (n->listCompletionMethod == SC_AC_TAB && !s._autoCInsertWithTab)
	{
		sci(v, SCI_AUTOCCANCEL);
		sci(v, SCI_TAB);
	}
}

// Port of Notepad_plus::maintainIndentation.
- (void)maintainIndentation:(int)ch
{
	const NppSettings& s = NppSettings::instance();
	ScintillaView* v = self.editor;
	intptr_t eolMode = sci(v, SCI_GETEOLMODE);
	intptr_t curLine = sci(v, SCI_LINEFROMPOSITION, sci(v, SCI_GETCURRENTPOS));
	intptr_t prevLine = curLine - 1;
	intptr_t indentAmountPrevLine = 0;
	intptr_t tabWidth = sci(v, SCI_GETTABWIDTH);
	bool isNewLine = ((eolMode == SC_EOL_CRLF || eolMode == SC_EOL_LF) && ch == '\n') || (eolMode == SC_EOL_CR && ch == '\r');

	if (isNewLine && prevLine >= 0 && lineLength(v, prevLine) == 0)
		return;

	const NppLang* lang = [self currentBuffer].lang;
	int type = lang ? LangManager::instance().langTypeOf(lang) : L_TEXT;

	auto basic = [&] {
		if (!isNewLine)
			return;
		while (prevLine >= 0 && lineLength(v, prevLine) == 0)
			prevLine--;
		if (prevLine >= 0)
			indentAmountPrevLine = sci(v, SCI_GETLINEINDENTATION, prevLine);
		if (indentAmountPrevLine > 0)
			setLineIndent(v, curLine, indentAmountPrevLine);
	};

	if (s._maintainIndent == 1)
	{
		basic();
		return;
	}

	if (type == L_C || type == L_CPP || type == L_JAVA || type == L_CS || type == L_OBJC ||
	    type == L_PHP || type == L_JS_EMBEDDED || type == L_JAVASCRIPT || type == L_JSP || type == L_CSS || type == L_PERL ||
	    type == L_RUST || type == L_POWERSHELL || type == L_JSON || type == L_JSON5 || type == L_TYPESCRIPT || type == L_GOLANG || type == L_SWIFT)
	{
		if (isNewLine)
		{
			while (prevLine >= 0 && lineLength(v, prevLine) == 0)
				prevLine--;
			if (prevLine >= 0)
				indentAmountPrevLine = sci(v, SCI_GETLINEINDENTATION, prevLine);

			intptr_t prevPos = sci(v, SCI_GETCURRENTPOS) - (eolMode == SC_EOL_CRLF ? 3 : 2);
			unsigned char prevChar = static_cast<unsigned char>(sci(v, SCI_GETCHARAT, prevPos));
			auto curPos = sci(v, SCI_GETCURRENTPOS);
			unsigned char nextChar = static_cast<unsigned char>(sci(v, SCI_GETCHARAT, curPos));

			if (prevChar == '{')
			{
				if (nextChar == '}')
				{
					const char* eolChars = eolMode == SC_EOL_CRLF ? "\r\n" : eolMode == SC_EOL_LF ? "\n" : "\r";
					sci(v, SCI_INSERTTEXT, sci(v, SCI_GETCURRENTPOS), reinterpret_cast<sptr_t>(eolChars));
					setLineIndent(v, curLine + 1, indentAmountPrevLine);
				}
				setLineIndent(v, curLine, indentAmountPrevLine + tabWidth);
			}
			else if (nextChar == '{')
				setLineIndent(v, curLine, indentAmountPrevLine);
			else if (type == L_PERL || type == L_RUST || type == L_POWERSHELL || type == L_JSON || type == L_JSON5)
				setLineIndent(v, curLine, indentAmountPrevLine);
			else if (isConditionExprLine(v, prevLine))
				setLineIndent(v, curLine, indentAmountPrevLine + tabWidth);
			else if (indentAmountPrevLine > 0)
			{
				if (prevLine > 0 && isConditionExprLine(v, prevLine - 1))
					setLineIndent(v, curLine, indentAmountPrevLine - tabWidth);
				else
					setLineIndent(v, curLine, indentAmountPrevLine);
			}
		}
		else if (ch == '{')
		{
			auto startPos = sci(v, SCI_POSITIONFROMLINE, curLine);
			intptr_t endPos = sci(v, SCI_GETCURRENTPOS);
			for (intptr_t i = endPos - 2; i > 0 && i >= startPos; --i)
			{
				unsigned char aChar = static_cast<unsigned char>(sci(v, SCI_GETCHARAT, i));
				if (aChar != ' ' && aChar != '\t')
					return;
			}
			while (prevLine >= 0 && lineLength(v, prevLine) == 0)
				prevLine--;
			if (prevLine >= 0)
			{
				indentAmountPrevLine = sci(v, SCI_GETLINEINDENTATION, prevLine);
				if (searchWholeLine(v, prevLine, "[ \t]*\\{.*"))
					indentAmountPrevLine += tabWidth;
			}
			setLineIndent(v, curLine, indentAmountPrevLine);
		}
		else if (ch == '}')
		{
			intptr_t startPos = sci(v, SCI_GETCURRENTPOS);
			if (startPos != 0)
				startPos -= 1;
			intptr_t posFound = findMatchedBracePos(v, startPos - 1, 0, '{', '}');
			if (posFound == -1)
				return;
			intptr_t matchedPairLine = sci(v, SCI_LINEFROMPOSITION, posFound);
			if (matchedPairLine == curLine)
				return;
			setLineIndent(v, curLine, sci(v, SCI_GETLINEINDENTATION, matchedPairLine));
		}
	}
	else if (type == L_PYTHON)
	{
		if (!isNewLine)
			return;
		while (prevLine >= 0 && lineLength(v, prevLine) == 0)
			prevLine--;
		if (prevLine >= 0)
			indentAmountPrevLine = sci(v, SCI_GETLINEINDENTATION, prevLine);

		sci(v, SCI_SETSEARCHFLAGS, SCFIND_REGEXP | SCFIND_POSIX);
		sci(v, SCI_SETTARGETRANGE, sci(v, SCI_POSITIONFROMLINE, prevLine), sci(v, SCI_GETLINEENDPOSITION, prevLine));
		const char colonExpr[] = ":[ \t]*(#|$)";
		auto posColon = sci(v, SCI_SEARCHINTARGET, strlen(colonExpr), reinterpret_cast<sptr_t>(colonExpr));
		if (posColon >= 0 && sci(v, SCI_GETSTYLEINDEXAT, posColon) == SCE_P_OPERATOR)
			setLineIndent(v, curLine, indentAmountPrevLine + tabWidth);
		else if (indentAmountPrevLine > 0)
			setLineIndent(v, curLine, indentAmountPrevLine);
	}
	else
		basic();
}

@end
