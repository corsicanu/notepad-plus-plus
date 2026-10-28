// Port of PowerEditor's AutoCompletion and FunctionCallTip: word and API
// (autoCompletion/*.xml) completion, function call tips with overloads,
// path completion and auto-insertion of matched pairs.
#pragma once

#import "ScintillaView.h"

#include "NppXml.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

// Settings > Preferences > Auto-Completion (NppGUI fields).
struct NppAutoCompletionSettings
{
	enum AutocStatus { autoc_none, autoc_func, autoc_word, autoc_both };
	AutocStatus _autocStatus = autoc_both;
	unsigned _autocFromLen = 1;
	bool _autocIgnoreNumbers = true;
	bool _autocBrief = false;
	bool _funcParams = true;
};

// MatchedPairConf.
struct NppMatchedPairConf
{
	std::vector<std::pair<char, char>> _matchedPairs;
	bool _doHtmlXmlTag = false;
	bool _doParentheses = false;
	bool _doBrackets = false;
	bool _doCurlyBrackets = false;
	bool _doQuotes = false;
	bool _doDoubleQuotes = false;

	bool hasUserDefinedPairs() const { return !_matchedPairs.empty(); }
	bool hasDefaultPairs() const { return _doParentheses || _doBrackets || _doCurlyBrackets || _doQuotes || _doDoubleQuotes || _doHtmlXmlTag; }
	bool hasAnyPairsPair() const { return hasUserDefinedPairs() || hasDefaultPairs(); }
};

class NppFunctionCallTip
{
	friend class NppAutoCompletion;
public:
	explicit NppFunctionCallTip(ScintillaView* view) : _view(view) {}
	void setLanguageXML(pugi::xml_node xmlKeyword);
	bool updateCalltip(int ch, bool needShown = false);
	void showNextOverload();
	void showPrevOverload();
	bool isVisible() const;
	void close();

private:
	using stringVec = std::vector<const char*>;

	__unsafe_unretained ScintillaView* _view = nil;
	pugi::xml_node _xmlKeyword;
	intptr_t _curPos = 0;
	intptr_t _startPos = 0;
	pugi::xml_node _curFunction;
	std::unique_ptr<char[]> _funcName;
	stringVec _retVals;
	std::vector<stringVec> _overloads;
	stringVec _descriptions;
	size_t _currentNbOverloads = 0;
	size_t _currentOverload = 0;
	size_t _currentParam = 0;

	char _start = '(';
	char _stop = ')';
	char _param = ',';
	char _terminal = ';';
	std::string _additionalWordChar;
	bool _ignoreCase = true;
	bool _selfActivated = false;

	bool getCursorFunction();
	bool loadFunction();
	void showCalltip();
	void reset();
	bool isAdditionalWordChar(char ch) const { return _additionalWordChar.find(ch) != std::string::npos; }
};

class NppAutoCompletion
{
public:
	enum AutocompleteType { autocFunc, autocWord, autocFuncAndWord, autocFuncBrief };

	explicit NppAutoCompletion(ScintillaView* view) : _view(view), _funcCalltip(view), _insertedMatchedChars(view) {}

	// `apiName` is the autoCompletion/<apiName>.xml file; `isHTML` / `isXML`
	// enable closing-tag insertion. Returns true when API completion is active.
	bool setLanguage(int langType, const std::string& apiName);

	bool showApiComplete();
	bool showApiAndWordComplete();
	bool showWordComplete(bool autoInsert);
	void showPathCompletion();
	bool showFunctionComplete();

	void insertMatchedChars(int character, const NppMatchedPairConf& matchedPairConf);
	void update(int character, const NppAutoCompletionSettings& s);
	void callTipClick(size_t direction);

private:
	struct MatchedCharInserted
	{
		char _c;
		size_t _pos;
		MatchedCharInserted(char c, size_t pos) : _c(c), _pos(pos) {}
	};

	class InsertedMatchedChars
	{
	public:
		explicit InsertedMatchedChars(ScintillaView* view) : _view(view) {}
		void removeInvalidElements(MatchedCharInserted mci);
		void add(MatchedCharInserted mci);
		bool isEmpty() const { return _insertedMatchedChars.empty(); }
		intptr_t search(char startChar, char endChar, size_t posToDetect);
	private:
		std::vector<MatchedCharInserted> _insertedMatchedChars;
		__unsafe_unretained ScintillaView* _view = nil;
	};

	__unsafe_unretained ScintillaView* _view = nil;
	bool _funcCompletionActive = false;
	int _curLang = -1;
	std::string _curApiName;
	std::unique_ptr<pugi::xml_document> _xmlFile;
	pugi::xml_node _xmlKeyword;
	bool _ignoreCase = true;
	std::vector<std::string> _keyWordArray;
	std::string _keyWords;
	size_t _keyWordMaxLen = 0;
	NppFunctionCallTip _funcCalltip;
	InsertedMatchedChars _insertedMatchedChars;
	bool _isFxImageRegistered = false;
	bool _isFxImageRegisteredDark = false;

	bool showAutoComplete(AutocompleteType autocType, bool autoInsert);
	void getWordArray(std::vector<std::string>& wordArray, const char* beginChars, const char* excludeChars) const;
	void getCloseTag(char* closeTag, size_t closeTagLen, size_t caretPos, bool isHTML) const;
};
