#import "NppAutoCompletion.h"
#import "NppTheme.h"

#include "NppSettings.h"
#include "NppUpstream.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <locale>
#include <sstream>
#include <string_view>

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

// FUNC_IMG_ID, BOX_IMG_ID and their XPMs, from upstream AutoCompletion.cpp.
#include "AutoCompletionImages.inc"

namespace
{
	constexpr size_t tagMaxLen = 256;

	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	// ScintillaEditView::getGenericText / getText.
	void getText(ScintillaView* v, char* dest, size_t destLen, intptr_t start, intptr_t end)
	{
		if (end - start >= static_cast<intptr_t>(destLen))
			end = start + destLen - 1;
		Sci_TextRangeFull tr{{start, end}, dest};
		sci(v, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
	}

	// ScintillaEditView::searchInTarget.
	intptr_t searchInTarget(ScintillaView* v, std::string_view text, intptr_t fromPos, intptr_t toPos)
	{
		sci(v, SCI_SETTARGETRANGE, fromPos, toPos);
		return sci(v, SCI_SEARCHINTARGET, text.size(), reinterpret_cast<sptr_t>(text.data()));
	}

	// ScintillaEditView::replaceTarget.
	intptr_t replaceTarget(ScintillaView* v, const std::string& str, intptr_t fromTargetPos, intptr_t toTargetPos)
	{
		if (fromTargetPos != -1 || toTargetPos != -1)
			sci(v, SCI_SETTARGETRANGE, fromTargetPos, toTargetPos);
		return sci(v, SCI_REPLACETARGET, static_cast<uptr_t>(-1), reinterpret_cast<sptr_t>(str.c_str()));
	}

	const std::locale& sysLocale()
	{
		static std::locale loc("");
		return loc;
	}

	bool isInList(const std::string& word, const std::vector<std::string>& wordArray)
	{
		return std::find(wordArray.begin(), wordArray.end(), word) != wordArray.end();
	}

	bool isAllDigits(const std::string& str)
	{
		static const auto& loc = std::locale::classic();
		return std::all_of(str.begin(), str.end(), [](auto c) { return std::isdigit(c, loc); });
	}

	void sortInsensitive(std::vector<std::string>& wordArray)
	{
		std::sort(wordArray.begin(), wordArray.end(), [](const std::string& a, const std::string& b) {
			return std::lexicographical_compare(a.begin(), a.end(), b.begin(), b.end(), [](const auto& ch1, const auto& ch2) {
				return std::toupper(ch1, sysLocale()) < std::toupper(ch2, sysLocale());
			});
		});
	}

	// FunctionCallTip.cpp
	int testNameNoCase(const char* name1, const char* name2, int len = -1)
	{
		if (len == -1)
			len = 1024;
		for (int i = 0; i < len; ++i)
		{
			const char char1 = name1[i];
			const char char2 = name2[i];
			if (char1 == '\0' || char2 == '\0')
				return char1 - char2;
			if (char1 == char2)
				continue;
			if (std::tolower(char1, sysLocale()) != std::tolower(char2, sysLocale()))
				return char1 - char2;
		}
		return 0;
	}

	bool isBasicWordChar(char ch)
	{
		static const auto& loc = std::locale::classic();
		return std::isalnum(ch, loc) || ch == '_';
	}

	int skipStringLiteral(const char* lineData, int i, intptr_t offset)
	{
		char quote = lineData[i];
		++i;
		while (i < offset && lineData[i] != quote)
		{
			if (lineData[i] == '\\' && i + 1 < offset)
				++i;
			++i;
		}
		return i;
	}

	struct Token
	{
		char* token;
		int length;
		bool isIdentifier;
		Token(char* tok, int len, bool isID) : token(tok), length(len), isIdentifier(isID) {}
	};

	struct FunctionValues
	{
		int lastIdentifier = -1;
		int lastFunctionIdentifier = -1;
		int param = 0;
		int scopeLevel = -1;
	};

	bool isDirectory(const std::string& p)
	{
		struct stat st;
		return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
	}

	bool isFile(const std::string& p)
	{
		struct stat st;
		return stat(p.c_str(), &st) == 0 && !S_ISDIR(st.st_mode);
	}

	// macOS counterpart of getRawPath: the path starts at the last "/" or "~/"
	// that begins a word (preceded by nothing, whitespace, a quote or "(").
	bool getRawPath(const std::string& input, std::string& rawPath)
	{
		for (size_t i = input.size(); i-- > 0;)
		{
			char c = input[i];
			if (c != '/' && !(c == '~' && i + 1 < input.size() && input[i + 1] == '/'))
				continue;
			char before = i ? input[i - 1] : ' ';
			if (before == '\'' || before == '"' || before == '(' || std::isspace(static_cast<unsigned char>(before)))
			{
				rawPath = input.substr(i);
				return rawPath.find_first_of(" \t\"'") == std::string::npos;
			}
		}
		return false;
	}
}

#pragma mark - FunctionCallTip

void NppFunctionCallTip::setLanguageXML(pugi::xml_node xmlKeyword)
{
	if (isVisible())
		close();
	_xmlKeyword = xmlKeyword;
	reset();
	_funcName.reset(nullptr);
}

bool NppFunctionCallTip::isVisible() const
{
	return _view && sci(_view, SCI_CALLTIPACTIVE) != 0;
}

bool NppFunctionCallTip::updateCalltip(int ch, bool needShown)
{
	if (!needShown && ch != _start && ch != _param && !isVisible())
		return false;

	_curPos = sci(_view, SCI_GETCURRENTPOS);
	if (!getCursorFunction())
	{
		close();
		return false;
	}
	showCalltip();
	return true;
}

void NppFunctionCallTip::showNextOverload()
{
	if (!isVisible())
		return;
	if (_currentNbOverloads > 0)
		_currentOverload = (_currentOverload + 1) % _currentNbOverloads;
	showCalltip();
}

void NppFunctionCallTip::showPrevOverload()
{
	if (!isVisible())
		return;
	_currentOverload = _currentOverload > 0 ? (_currentOverload - 1) : (_currentNbOverloads - 1);
	showCalltip();
}

void NppFunctionCallTip::close()
{
	if (!isVisible() || !_selfActivated)
		return;
	sci(_view, SCI_CALLTIPCANCEL);
	_selfActivated = false;
	_currentOverload = 0;
}

bool NppFunctionCallTip::getCursorFunction()
{
	auto line = sci(_view, SCI_LINEFROMPOSITION, _curPos);
	intptr_t startpos = sci(_view, SCI_POSITIONFROMLINE, line);
	intptr_t endpos = sci(_view, SCI_GETLINEENDPOSITION, line);
	intptr_t len = endpos - startpos + 3;
	intptr_t offset = _curPos - startpos;
	static constexpr intptr_t maxLen = 256;

	if (offset < 2 || len >= maxLen)
	{
		reset();
		return false;
	}

	char lineData[maxLen]{};
	getText(_view, lineData, maxLen, startpos, std::min<intptr_t>(sci(_view, SCI_GETLENGTH), startpos + len - 1));

	std::vector<Token> tokenVector;
	for (int i = 0; i < offset; ++i)
	{
		char ch = lineData[i];
		if (isBasicWordChar(ch) || isAdditionalWordChar(ch))
		{
			int tokenLen = 0;
			char* begin = lineData + i;
			while ((isBasicWordChar(ch) || isAdditionalWordChar(ch)) && i < offset)
			{
				++tokenLen;
				++i;
				ch = lineData[i];
			}
			tokenVector.emplace_back(begin, tokenLen, true);
			--i;
		}
		else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
		{
		}
		else if (ch == '"' || ch == '\'')
			i = skipStringLiteral(lineData, i, offset);
		else
			tokenVector.emplace_back(lineData + i, 1, false);
	}

	size_t vsize = tokenVector.size();
	std::vector<FunctionValues> valueVec;
	FunctionValues curValue, newValue;
	int scopeLevel = 0;
	for (size_t i = 0; i < vsize; ++i)
	{
		const Token& curToken = tokenVector.at(i);
		if (curToken.isIdentifier)
			curValue.lastIdentifier = static_cast<int>(i);
		else if (curToken.token[0] == _start)
		{
			++scopeLevel;
			newValue = curValue;
			valueVec.push_back(newValue);
			curValue.scopeLevel = scopeLevel;
			if (i > 0 && curValue.lastIdentifier == static_cast<int>(i) - 1)
			{
				curValue.lastFunctionIdentifier = curValue.lastIdentifier;
				curValue.param = 0;
			}
			else
				curValue.lastFunctionIdentifier = -1;
		}
		else if (curToken.token[0] == _param && curValue.lastFunctionIdentifier > -1)
			++curValue.param;
		else if (curToken.token[0] == _stop)
		{
			if (scopeLevel)
				--scopeLevel;
			if (!valueVec.empty())
			{
				curValue = valueVec.back();
				valueVec.pop_back();
			}
			else
				curValue = FunctionValues();
		}
		else if (curToken.token[0] == _terminal)
		{
			valueVec.clear();
			curValue = FunctionValues();
		}
	}

	bool res = false;
	if (curValue.lastFunctionIdentifier == -1)
	{
		while (curValue.lastFunctionIdentifier == -1 && !valueVec.empty())
		{
			curValue = valueVec.back();
			valueVec.pop_back();
		}
	}

	if (curValue.lastFunctionIdentifier > -1)
	{
		Token funcToken = tokenVector.at(curValue.lastFunctionIdentifier);
		funcToken.token[funcToken.length] = 0;
		_currentParam = curValue.param;

		bool same = false;
		if (_funcName)
		{
			if (_ignoreCase)
				same = testNameNoCase(_funcName.get(), funcToken.token, static_cast<int>(std::strlen(_funcName.get()))) == 0;
			else
				same = std::strncmp(_funcName.get(), funcToken.token, std::strlen(_funcName.get())) == 0;
		}

		if (!same)
		{
			_funcName.reset(new char[funcToken.length + 1]);
			std::memcpy(_funcName.get(), funcToken.token, funcToken.length + 1);
			res = loadFunction();
		}
		else
			res = true;
	}
	return res;
}

bool NppFunctionCallTip::loadFunction()
{
	reset();
	_curFunction = {};
	for (pugi::xml_node funcNode = _xmlKeyword; funcNode; funcNode = funcNode.next_sibling("KeyWord"))
	{
		const char* name = funcNode.attribute("name").as_string(nullptr);
		if (!name)
			continue;
		int compVal = _ignoreCase ? testNameNoCase(name, _funcName.get()) : std::strcmp(name, _funcName.get());
		if (compVal == 0)
		{
			const char* val = funcNode.attribute("func").as_string(nullptr);
			if (val)
			{
				if (std::strcmp(val, "yes") == 0)
				{
					_curFunction = funcNode;
					break;
				}
				return false;
			}
		}
	}

	if (!_curFunction)
		return false;

	stringVec paramVec;
	for (pugi::xml_node overloadNode = _curFunction.child("Overload"); overloadNode; overloadNode = overloadNode.next_sibling("Overload"))
	{
		const char* retVal = overloadNode.attribute("retVal").as_string(nullptr);
		if (!retVal)
			continue;
		_retVals.push_back(retVal);
		_descriptions.push_back(overloadNode.attribute("descr").as_string(""));
		for (pugi::xml_node paramNode = overloadNode.child("Param"); paramNode; paramNode = paramNode.next_sibling("Param"))
		{
			const char* param = paramNode.attribute("name").as_string(nullptr);
			if (param)
				paramVec.push_back(param);
		}
		_overloads.push_back(paramVec);
		paramVec.clear();
	}

	_currentNbOverloads = _overloads.size();
	return _currentNbOverloads != 0;
}

void NppFunctionCallTip::showCalltip()
{
	if (_currentNbOverloads == 0)
		return;

	const stringVec& params = _overloads.at(_currentOverload);
	size_t psize = params.size() + 1;
	if (_currentParam >= psize)
	{
		for (size_t i = 0, osize = _overloads.size(); i < osize; ++i)
		{
			psize = _overloads.at(i).size() + 1;
			if (_currentParam < psize)
			{
				_currentOverload = i;
				break;
			}
		}
	}
	const stringVec& shown = _overloads.at(_currentOverload);

	std::stringstream callTipText;
	if (_currentNbOverloads > 1)
		callTipText << "\001" << _currentOverload + 1 << " of " << _currentNbOverloads << "\002";
	callTipText << _retVals.at(_currentOverload) << ' ' << _funcName.get() << ' ' << _start;

	int highlightstart = 0;
	int highlightend = 0;
	size_t nbParams = shown.size();
	for (size_t i = 0; i < nbParams; ++i)
	{
		if (i == _currentParam)
		{
			highlightstart = static_cast<int>(callTipText.str().length());
			highlightend = highlightstart + static_cast<int>(std::strlen(shown.at(i)));
		}
		callTipText << shown.at(i);
		if (i < nbParams - 1)
			callTipText << _param << ' ';
	}

	callTipText << _stop;
	if (_descriptions.at(_currentOverload)[0])
		callTipText << "\n" << _descriptions.at(_currentOverload);

	if (isVisible())
		sci(_view, SCI_CALLTIPCANCEL);
	else
		_startPos = _curPos;
	std::string text = callTipText.str();
	sci(_view, SCI_CALLTIPSHOW, _startPos, reinterpret_cast<sptr_t>(text.c_str()));

	_selfActivated = true;
	if (highlightstart != highlightend)
		sci(_view, SCI_CALLTIPSETHLT, highlightstart, highlightend);
}

void NppFunctionCallTip::reset()
{
	_currentOverload = 0;
	_currentParam = 0;
	_startPos = 0;
	_overloads.clear();
	_currentNbOverloads = 0;
	_retVals.clear();
	_descriptions.clear();
}

#pragma mark - AutoCompletion

bool NppAutoCompletion::showAutoComplete(AutocompleteType autocType, bool autoInsert)
{
	if (autocType == autocFunc && !_funcCompletionActive)
		return false;

	intptr_t curPos = sci(_view, SCI_GETCURRENTPOS);
	intptr_t startPos = sci(_view, SCI_WORDSTARTPOSITION, curPos, true);
	if (curPos == startPos)
		return false;

	const auto len = static_cast<size_t>(std::abs(curPos - startPos));
	std::string words;

	if (autocType == autocFunc)
	{
		if (len >= _keyWordMaxLen)
			return false;
	}
	else
	{
		static constexpr size_t bufSize = 256;
		if (len >= bufSize)
			return false;

		intptr_t endPos = sci(_view, SCI_WORDENDPOSITION, curPos, true);
		const auto lena = static_cast<size_t>(std::abs(endPos - startPos));
		if (lena >= bufSize)
			return false;

		char beginChars[bufSize]{};
		getText(_view, beginChars, bufSize, startPos, curPos);

		std::vector<std::string> wordArray;
		if (autocType == autocWord || autocType == autocFuncAndWord)
		{
			char excludeChars[bufSize]{};
			getText(_view, excludeChars, bufSize, startPos, endPos);
			getWordArray(wordArray, beginChars, excludeChars);
		}

		if (autocType == autocFuncBrief || autocType == autocFuncAndWord)
		{
			for (const auto& kw : _keyWordArray)
			{
				int compareResult = _ignoreCase ? ::strcasecmp(beginChars, kw.substr(0, len).c_str()) : kw.compare(0, len, beginChars);
				if (compareResult == 0 && !isInList(kw, wordArray))
					wordArray.push_back(kw);
			}
		}

		if (wordArray.empty())
			return false;

		if (autocType == autocWord && wordArray.size() == 1 && autoInsert)
		{
			const size_t typeSeparatorPos = wordArray[0].find("\x1E");
			intptr_t replacedLength = replaceTarget(_view, typeSeparatorPos == std::string::npos ? wordArray[0] : wordArray[0].substr(0, typeSeparatorPos), startPos, curPos);
			sci(_view, SCI_GOTOPOS, startPos + replacedLength);
			return true;
		}

		if (autocType == autocWord || autocType & autocFuncAndWord)
		{
			if (_ignoreCase)
				sortInsensitive(wordArray);
			else
				std::sort(wordArray.begin(), wordArray.end());
		}

		for (size_t i = 0, n = wordArray.size(); i < n; ++i)
		{
			words += wordArray[i];
			if (i != n - 1)
				words += " ";
		}
	}

	if ([NppTheme isDark])
	{
		if (!_isFxImageRegisteredDark)
		{
			sci(_view, SCI_CLEARREGISTEREDIMAGES);
			sci(_view, SCI_REGISTERIMAGE, FUNC_IMG_ID, reinterpret_cast<sptr_t>(xpmfnDark));
			sci(_view, SCI_REGISTERIMAGE, BOX_IMG_ID, reinterpret_cast<sptr_t>(xpmboxDark));
			_isFxImageRegistered = false;
			_isFxImageRegisteredDark = true;
		}
	}
	else if (!_isFxImageRegistered)
	{
		sci(_view, SCI_CLEARREGISTEREDIMAGES);
		sci(_view, SCI_REGISTERIMAGE, FUNC_IMG_ID, reinterpret_cast<sptr_t>(xpmfn));
		sci(_view, SCI_REGISTERIMAGE, BOX_IMG_ID, reinterpret_cast<sptr_t>(xpmbox));
		_isFxImageRegistered = true;
		_isFxImageRegisteredDark = false;
	}

	sci(_view, SCI_AUTOCSETTYPESEPARATOR, '\x1E');
	sci(_view, SCI_AUTOCSETSEPARATOR, ' ');
	sci(_view, SCI_AUTOCSETIGNORECASE, _ignoreCase);
	sci(_view, SCI_AUTOCSETCASEINSENSITIVEBEHAVIOUR, _ignoreCase);

	const std::string& list = autocType == autocFunc ? _keyWords : words;
	sci(_view, SCI_AUTOCSHOW, curPos - startPos, reinterpret_cast<sptr_t>(list.c_str()));
	return true;
}

bool NppAutoCompletion::showApiComplete()
{
	return showAutoComplete(autocFunc, false);
}

bool NppAutoCompletion::showApiAndWordComplete()
{
	return showAutoComplete(autocFuncAndWord, false);
}

bool NppAutoCompletion::showWordComplete(bool autoInsert)
{
	return showAutoComplete(autocWord, autoInsert);
}

void NppAutoCompletion::getWordArray(std::vector<std::string>& wordArray, const char* beginChars, const char* excludeChars) const
{
	static constexpr size_t bufSize = 256;
	if (NppSettings::instance()._autoCIgnoreNumbers && isAllDigits(beginChars))
		return;

	std::string expr = "\\<";
	expr += beginChars;
	expr += "[^ \\t\\n\\r.,;:\"(){}=<>'+!?\\[\\]]+";

	size_t docLength = sci(_view, SCI_GETLENGTH);
	int flags = SCFIND_WORDSTART | SCFIND_REGEXP | SCFIND_POSIX;
	if (!_ignoreCase || (!_funcCompletionActive && _curLang == L_TEXT))
		flags |= SCFIND_MATCHCASE;

	sci(_view, SCI_SETSEARCHFLAGS, flags);
	intptr_t posFind = searchInTarget(_view, expr, 0, docLength);

	const std::string boxId = "\x1E" + std::to_string(BOX_IMG_ID);
	const std::string funcId = "\x1E" + std::to_string(FUNC_IMG_ID);

	while (posFind >= 0)
	{
		intptr_t wordStart = sci(_view, SCI_GETTARGETSTART);
		intptr_t wordEnd = sci(_view, SCI_GETTARGETEND);
		size_t foundTextLen = wordEnd - wordStart;
		if (foundTextLen < bufSize)
		{
			char w[bufSize]{};
			getText(_view, w, bufSize, wordStart, wordEnd);
			if (!excludeChars || std::strncmp(w, excludeChars, bufSize) != 0)
			{
				if (_funcCompletionActive)
				{
					if (isInList(w + boxId, _keyWordArray))
					{
						if (!isInList(w + boxId, wordArray))
							wordArray.push_back(w + boxId);
					}
					else if (isInList(w + funcId, _keyWordArray))
					{
						if (!isInList(w + funcId, wordArray))
							wordArray.push_back(w + funcId);
					}
					else if (!isInList(w, wordArray))
						wordArray.push_back(w);
				}
				else if (!isInList(w, wordArray))
					wordArray.push_back(w);
			}
		}
		posFind = searchInTarget(_view, expr, wordEnd, docLength);
	}
}

// Port of showPathCompletion for POSIX paths ("/usr/lo", "~/Doc").
void NppAutoCompletion::showPathCompletion()
{
	static constexpr intptr_t bufSize = 1024;
	const intptr_t currentPos = sci(_view, SCI_GETCURRENTPOS);
	const intptr_t lineStart = sci(_view, SCI_POSITIONFROMLINE, sci(_view, SCI_LINEFROMPOSITION, currentPos));
	const intptr_t startPos = std::max<intptr_t>(lineStart, currentPos - bufSize);
	std::string currentLine(currentPos - startPos + 1, '\0');
	getText(_view, currentLine.data(), currentLine.size(), startPos, currentPos);
	currentLine.resize(currentPos - startPos);

	std::string rawPath;
	if (!getRawPath(currentLine, rawPath))
		return;
	std::string expanded = rawPath;
	if (expanded[0] == '~')
		expanded = std::string(getenv("HOME") ?: "") + expanded.substr(1);

	std::string pathToMatch;
	if (isFile(expanded))
		return;
	if (isDirectory(expanded) && expanded.back() == '/')
		pathToMatch = expanded;
	else
	{
		size_t last = expanded.rfind('/');
		if (last == std::string::npos)
			return;
		pathToMatch = expanded.substr(0, last + 1);
	}
	// Entries are listed as the user wrote the directory ("~/" stays "~/").
	std::string shownDir = rawPath.substr(0, rawPath.size() - (expanded.size() - pathToMatch.size()));

	DIR* dir = opendir(pathToMatch.c_str());
	if (!dir)
		return;
	std::string entries;
	static constexpr unsigned int maxEntries = 2000;
	unsigned int counter = 0;
	while (dirent* e = readdir(dir))
	{
		if (++counter > maxEntries)
			break;
		if (std::strcmp(e->d_name, ".") == 0 || std::strcmp(e->d_name, "..") == 0)
			continue;
		if (!entries.empty())
			entries += "\n";
		entries += shownDir + e->d_name;
		if (isDirectory(pathToMatch + e->d_name))
			entries += "/";
	}
	closedir(dir);
	if (entries.empty())
		return;

	sci(_view, SCI_AUTOCSETSEPARATOR, '\n');
	sci(_view, SCI_AUTOCSETIGNORECASE, true);
	sci(_view, SCI_AUTOCSETCASEINSENSITIVEBEHAVIOUR, true);
	sci(_view, SCI_AUTOCSHOW, rawPath.length(), reinterpret_cast<sptr_t>(entries.c_str()));
}

bool NppAutoCompletion::showFunctionComplete()
{
	if (!_funcCompletionActive)
		return false;
	return _funcCalltip.updateCalltip(0, true);
}

void NppAutoCompletion::getCloseTag(char* closeTag, size_t closeTagLen, size_t caretPos, bool isHTML) const
{
	if (isHTML)
	{
		size_t style = sci(_view, SCI_GETSTYLEAT, caretPos);
		if (style >= SCE_HJ_START)
			return;
	}

	char prev = static_cast<char>(sci(_view, SCI_GETCHARAT, caretPos - 2));
	char prevprev = static_cast<char>(sci(_view, SCI_GETCHARAT, caretPos - 3));
	if (prevprev == '-' && prev == '-')
		return;
	if (prev == '/')
		return;

	sci(_view, SCI_SETSEARCHFLAGS, SCFIND_REGEXP | SCFIND_POSIX);
	static constexpr std::string_view tag2find = "<[^\\s>]*";
	const intptr_t targetStart = searchInTarget(_view, tag2find, caretPos, 0);
	if (targetStart < 0)
		return;

	intptr_t targetEnd = sci(_view, SCI_GETTARGETEND);
	intptr_t foundTextLen = targetEnd - targetStart;
	if (foundTextLen < 2)
		return;
	if (foundTextLen > static_cast<intptr_t>(closeTagLen) - 2)
		return;

	char tagHead[tagMaxLen]{};
	getText(_view, tagHead, tagMaxLen, targetStart, targetEnd);
	if (tagHead[1] == '/' || tagHead[1] == '?')
		return;
	if (std::strncmp(tagHead, "<!--", 4) == 0)
		return;

	if (isHTML)
	{
		static constexpr const char* disallowedTags[]{
			"area", "base", "br", "col", "embed", "hr", "img", "input",
			"keygen", "link", "meta", "param", "source", "track", "wbr", "!doctype"
		};
		for (const char* t : disallowedTags)
			if (::strncasecmp(tagHead + 1, t, std::strlen(t)) == 0)
				return;
	}

	closeTag[0] = '<';
	closeTag[1] = '/';
	getText(_view, closeTag + 2, closeTagLen - 2, targetStart + 1, targetEnd);
	closeTag[foundTextLen + 1] = '>';
	closeTag[foundTextLen + 2] = '\0';
}

void NppAutoCompletion::InsertedMatchedChars::removeInvalidElements(MatchedCharInserted mci)
{
	if (mci._c == '\n' || mci._c == '\r')
	{
		_insertedMatchedChars.clear();
		return;
	}
	for (int i = static_cast<int>(_insertedMatchedChars.size()) - 1; i >= 0; --i)
	{
		if (_insertedMatchedChars[i]._pos < mci._pos)
		{
			auto posToDetectLine = sci(_view, SCI_LINEFROMPOSITION, mci._pos);
			auto startPosLine = sci(_view, SCI_LINEFROMPOSITION, _insertedMatchedChars[i]._pos);
			if (posToDetectLine != startPosLine)
				_insertedMatchedChars.erase(_insertedMatchedChars.begin() + i);
		}
		else
			_insertedMatchedChars.erase(_insertedMatchedChars.begin() + i);
	}
}

void NppAutoCompletion::InsertedMatchedChars::add(MatchedCharInserted mci)
{
	removeInvalidElements(mci);
	_insertedMatchedChars.push_back(mci);
}

intptr_t NppAutoCompletion::InsertedMatchedChars::search(char startChar, char endChar, size_t posToDetect)
{
	if (isEmpty())
		return -1;
	auto posToDetectLine = sci(_view, SCI_LINEFROMPOSITION, posToDetect);

	for (int i = static_cast<int>(_insertedMatchedChars.size()) - 1; i >= 0; --i)
	{
		if (_insertedMatchedChars[i]._c != startChar)
			continue;
		if (_insertedMatchedChars[i]._pos < posToDetect)
		{
			auto startPosLine = sci(_view, SCI_LINEFROMPOSITION, _insertedMatchedChars[i]._pos);
			if (posToDetectLine == startPosLine)
			{
				size_t endPos = sci(_view, SCI_GETLINEENDPOSITION, startPosLine);
				for (auto j = posToDetect; j <= endPos; ++j)
				{
					char aChar = static_cast<char>(sci(_view, SCI_GETCHARAT, j));
					if (aChar != ' ')
					{
						_insertedMatchedChars.erase(_insertedMatchedChars.begin() + i);
						return aChar == endChar ? static_cast<intptr_t>(j) : -1;
					}
				}
			}
			else
				_insertedMatchedChars.erase(_insertedMatchedChars.begin() + i);
		}
		else
			_insertedMatchedChars.erase(_insertedMatchedChars.begin() + i);
	}
	return -1;
}

void NppAutoCompletion::insertMatchedChars(int character, const NppMatchedPairConf& matchedPairConf)
{
	const size_t caretPos = sci(_view, SCI_GETCURRENTPOS);

	if (character > std::numeric_limits<char>::max())
	{
		if (!_insertedMatchedChars.isEmpty())
			_insertedMatchedChars.removeInvalidElements(MatchedCharInserted('\0', caretPos - 1));
		return;
	}

	const auto ch = static_cast<char>(character);
	const char* matchedChars = nullptr;

	char charPrev = static_cast<char>(sci(_view, SCI_GETCHARAT, caretPos - 2));
	char charNext = static_cast<char>(sci(_view, SCI_GETCHARAT, caretPos));

	bool isCharPrevBlank = charPrev == ' ' || charPrev == '\t' || charPrev == '\n' || charPrev == '\r' || charPrev == '\0';
	size_t docLen = sci(_view, SCI_GETLENGTH);
	bool isCharNextBlank = charNext == ' ' || charNext == '\t' || charNext == '\n' || charNext == '\r' || caretPos == docLen;
	bool isCharNextCloseSymbol = charNext == ')' || charNext == ']' || charNext == '}';
	bool isInSandwich = (charPrev == '(' && charNext == ')') || (charPrev == '[' && charNext == ']') || (charPrev == '{' && charNext == '}');

	for (const auto& matchedPair : matchedPairConf._matchedPairs)
	{
		if (matchedPair.first == ch && isCharNextBlank)
		{
			const char userMatchedChar[2]{ matchedPair.second, '\0' };
			sci(_view, SCI_INSERTTEXT, caretPos, reinterpret_cast<sptr_t>(userMatchedChar));
			return;
		}
	}

	auto quoteCondition = [&] {
		return (isCharPrevBlank && isCharNextBlank) || isInSandwich ||
		       (charPrev == '(' && isCharNextBlank) || (isCharPrevBlank && charNext == ')') ||
		       (charPrev == '[' && isCharNextBlank) || (isCharPrevBlank && charNext == ']') ||
		       (charPrev == '{' && isCharNextBlank) || (isCharPrevBlank && charNext == '}');
	};

	char closeTag[tagMaxLen]{};
	switch (ch)
	{
		case '(':
			if (matchedPairConf._doParentheses && (isCharNextBlank || isCharNextCloseSymbol))
			{
				matchedChars = ")";
				_insertedMatchedChars.add(MatchedCharInserted(ch, caretPos - 1));
			}
			break;

		case '[':
			if (matchedPairConf._doBrackets && (isCharNextBlank || isCharNextCloseSymbol))
			{
				matchedChars = "]";
				_insertedMatchedChars.add(MatchedCharInserted(ch, caretPos - 1));
			}
			break;

		case '{':
			if (matchedPairConf._doCurlyBrackets && (isCharNextBlank || isCharNextCloseSymbol))
			{
				matchedChars = "}";
				_insertedMatchedChars.add(MatchedCharInserted(ch, caretPos - 1));
			}
			break;

		case '"':
		case '\'':
		{
			bool enabled = ch == '"' ? matchedPairConf._doDoubleQuotes : matchedPairConf._doQuotes;
			if (!enabled)
				break;
			if (!_insertedMatchedChars.isEmpty())
			{
				intptr_t pos = _insertedMatchedChars.search(ch, ch, caretPos);
				if (pos != -1)
				{
					sci(_view, SCI_DELETERANGE, pos, 1);
					sci(_view, SCI_GOTOPOS, pos);
					return;
				}
			}
			if (quoteCondition())
			{
				matchedChars = ch == '"' ? "\"" : "'";
				_insertedMatchedChars.add(MatchedCharInserted(ch, caretPos - 1));
			}
			break;
		}

		case '>':
			if (matchedPairConf._doHtmlXmlTag && (_curLang == L_HTML || _curLang == L_XML))
			{
				getCloseTag(closeTag, tagMaxLen, caretPos, _curLang == L_HTML);
				if (closeTag[0] != '\0')
					matchedChars = closeTag;
			}
			break;

		case ')':
		case ']':
		case '}':
		{
			if (_insertedMatchedChars.isEmpty())
				break;
			char startChar;
			if (ch == ')')
			{
				if (!matchedPairConf._doParentheses)
					return;
				startChar = '(';
			}
			else if (ch == ']')
			{
				if (!matchedPairConf._doBrackets)
					return;
				startChar = '[';
			}
			else
			{
				if (!matchedPairConf._doCurlyBrackets)
					return;
				startChar = '{';
			}
			const intptr_t pos = _insertedMatchedChars.search(startChar, ch, caretPos);
			if (pos != -1)
			{
				sci(_view, SCI_DELETERANGE, pos, 1);
				sci(_view, SCI_GOTOPOS, pos);
			}
			return;
		}

		default:
			if (!_insertedMatchedChars.isEmpty())
				_insertedMatchedChars.removeInvalidElements(MatchedCharInserted(ch, caretPos - 1));
	}

	if (matchedChars)
		sci(_view, SCI_INSERTTEXT, caretPos, reinterpret_cast<sptr_t>(matchedChars));
}

void NppAutoCompletion::update(int character, const NppAutoCompletionSettings& s)
{
	if (!character)
		return;
	if (!_funcCompletionActive && s._autocStatus == NppAutoCompletionSettings::autoc_func)
		return;

	if (s._funcParams || _funcCalltip.isVisible())
	{
		if (_funcCalltip.updateCalltip(character))
			return;
	}

	if (!s._autocBrief && sci(_view, SCI_AUTOCACTIVE) != 0)
		return;

	// ScintillaEditView::getWordToCurrentPos
	static constexpr int wordSize = 64;
	char w[wordSize]{};
	const auto caretPos = sci(_view, SCI_GETCURRENTPOS);
	const auto startPos = sci(_view, SCI_WORDSTARTPOSITION, caretPos, true);
	if (caretPos - startPos < wordSize)
		getText(_view, w, wordSize, startPos, caretPos);

	if (std::strlen(w) >= size_t{ s._autocFromLen })
	{
		if (s._autocStatus == NppAutoCompletionSettings::autoc_word)
			showWordComplete(false);
		else if (s._autocStatus == NppAutoCompletionSettings::autoc_func)
		{
			if (s._autocBrief)
				showAutoComplete(autocFuncBrief, false);
			else
				showApiComplete();
		}
		else if (s._autocStatus == NppAutoCompletionSettings::autoc_both)
			showApiAndWordComplete();
	}
}

void NppAutoCompletion::callTipClick(size_t direction)
{
	if (!_funcCompletionActive)
		return;
	if (direction == 1)
		_funcCalltip.showPrevOverload();
	else if (direction == 2)
		_funcCalltip.showNextOverload();
}

bool NppAutoCompletion::setLanguage(int langType, const std::string& apiName)
{
	if (_curLang == langType && _curApiName == apiName && _xmlFile)
		return _funcCompletionActive;

	_curLang = langType;
	_curApiName = apiName;

	NSString* path = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: @"autoCompletion"]
		stringByAppendingPathComponent: [NSString stringWithFormat: @"%s.xml", apiName.c_str()]];
	_xmlFile = std::make_unique<pugi::xml_document>();
	_funcCompletionActive = !apiName.empty() && _xmlFile->load_file(path.fileSystemRepresentation);

	pugi::xml_node autoNode;
	if (_funcCompletionActive)
	{
		_funcCompletionActive = false;
		autoNode = _xmlFile->child("NotepadPlus").child("AutoComplete");
		pugi::xml_node node = autoNode.child("KeyWord");
		if (!node)
			return false;
		_xmlKeyword = node;
		_funcCompletionActive = true;
	}

	if (_funcCompletionActive)
	{
		_ignoreCase = true;
		_funcCalltip._start = '(';
		_funcCalltip._stop = ')';
		_funcCalltip._param = ',';
		_funcCalltip._terminal = ';';
		_funcCalltip._ignoreCase = true;
		_funcCalltip._additionalWordChar.clear();

		if (pugi::xml_node elem = autoNode.child("Environment"))
		{
			const char* val = elem.attribute("ignoreCase").as_string(nullptr);
			if (val && std::strcmp(val, "no") == 0)
			{
				_ignoreCase = false;
				_funcCalltip._ignoreCase = false;
			}
			if ((val = elem.attribute("startFunc").as_string(nullptr)) && val[0])
				_funcCalltip._start = val[0];
			if ((val = elem.attribute("stopFunc").as_string(nullptr)) && val[0])
				_funcCalltip._stop = val[0];
			if ((val = elem.attribute("paramSeparator").as_string(nullptr)) && val[0])
				_funcCalltip._param = val[0];
			if ((val = elem.attribute("terminal").as_string(nullptr)) && val[0])
				_funcCalltip._terminal = val[0];
			if ((val = elem.attribute("additionalWordChar").as_string(nullptr)) && val[0])
				_funcCalltip._additionalWordChar = val;
		}
	}

	_funcCalltip.setLanguageXML(_funcCompletionActive ? _xmlKeyword : pugi::xml_node());

	_keyWords.clear();
	_keyWordArray.clear();

	if (_funcCompletionActive)
	{
		for (pugi::xml_node funcNode = _xmlKeyword; funcNode; funcNode = funcNode.next_sibling("KeyWord"))
		{
			const char* name = funcNode.attribute("name").as_string(nullptr);
			if (!name)
				continue;
			const size_t len = std::strlen(name);
			if (len == 0)
				continue;
			std::string word = name;
			word += "\x1E";
			word += std::to_string(std::strcmp(funcNode.attribute("func").as_string(""), "yes") == 0 ? FUNC_IMG_ID : BOX_IMG_ID);
			_keyWordArray.push_back(word);
			if (len > _keyWordMaxLen)
				_keyWordMaxLen = len;
		}

		if (_ignoreCase)
			sortInsensitive(_keyWordArray);
		else
			std::sort(_keyWordArray.begin(), _keyWordArray.end());

		for (const auto& kw : _keyWordArray)
		{
			_keyWords.append(kw);
			_keyWords.append(" ");
		}
	}
	return _funcCompletionActive;
}
