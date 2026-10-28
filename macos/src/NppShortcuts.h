// shortcuts.xml: recorded macros and Run menu commands. Port of the parts of
// upstream's shortcut.h (recordedMacroStep, MacroShortcut, UserCommand),
// NppParameters (feedMacros, feedUserCmds, insertMacro, insertUserCmd,
// shortcuts.xml HMAC) and RunDlg (Command::run, $(VARIABLE) expansion).
#pragma once

#include "NppUpstream.h"

#include <functional>
#include <string>
#include <utility>
#include <vector>

// Port of recordedMacroStep.
struct NppMacroStep
{
	enum MacroTypeIndex { mtUseLParameter, mtUseSParameter, mtMenuCommand, mtSavedSnR };

	int _message = 0;
	uptr_t _wParameter = 0;
	uptr_t _lParameter = 0;
	std::string _sParameter;
	MacroTypeIndex _macroType = mtMenuCommand;

	// A Scintilla message from SCN_MACRORECORD.
	NppMacroStep(int iMessage, uptr_t wParam, uptr_t lParam);
	// A menu command.
	explicit NppMacroStep(int iCommandID) : _wParameter(iCommandID) {}
	NppMacroStep(int iMessage, uptr_t wParam, uptr_t lParam, const char* sParam, int type)
		: _message(iMessage), _wParameter(wParam), _lParameter(lParam), _sParameter(sParam ? sParam : ""), _macroType(static_cast<MacroTypeIndex>(type))
	{}

	bool isScintillaMacro() const { return _macroType <= mtMenuCommand; }
	bool isMacroable() const;
};

using NppMacro = std::vector<NppMacroStep>;

struct NppKeyCombo
{
	bool _isCtrl = false;
	bool _isAlt = false;
	bool _isShift = false;
	int _key = 0;
};

struct NppShortcutEntry
{
	std::string _name;
	NppKeyCombo _keyCombo;
	std::string _folderName;   // FolderName attribute: sub-menu in Macro / Run menu
};

struct NppMacroShortcut : NppShortcutEntry
{
	NppMacro _macro;
};

struct NppUserCommand : NppShortcutEntry
{
	std::string _cmd;
};

// <InternalCommands><Shortcut id Ctrl Alt Shift Key/>: a menu command's key, changed by the user.
struct NppInternalShortcut
{
	int _id = 0;
	NppKeyCombo _keyCombo;
};

// <ScintillaKeys><ScintKey ScintID menuCmdID Ctrl Alt Shift Key><NextKey .../>
struct NppScintillaKey
{
	int _scintId = 0;
	int _menuCmdId = 0;
	std::vector<NppKeyCombo> _keys;   // first one + NextKey entries; empty = no key
};

class NppShortcuts
{
public:
	static NppShortcuts& instance();

	// Reads shortcuts.xml from the settings folder (written from upstream's
	// SHORTCUT_XML_CONTENT when missing).
	void load();
	// Rewrites <InternalCommands>, <Macros>, <UserDefinedCommands> and <ScintillaKeys>, keeps the rest.
	bool save();

	std::string path() const;

	std::vector<NppMacroShortcut> _macros;
	std::vector<NppUserCommand> _userCommands;
	std::vector<NppInternalShortcut> _internalCommands;
	std::vector<NppScintillaKey> _scintillaKeys;

	// Integrity check of shortcuts.xml (config.xml "shortcutsXmlHMAC").
	// Returns false when the file must be reviewed and validated first.
	bool isTrusted() const;
	bool hmacMissing() const;
	void validate();                  // Run > Validate shortcuts.xml

	// Menu commands recorded in macros (upstream NppCommands.cpp list).
	static bool isMacroableCommand(int id);
	// Key names for the Shortcut dialog (upstream namedKeyArray).
	static const std::vector<std::pair<std::string, int>>& namedKeys();
	// "Ctrl+Alt+F1" style text, as Shortcut::toString.
	static std::string keyComboString(const NppKeyCombo& k);

private:
	std::string _onDiskHmac;
	void refreshHmac();
};

// Port of RunDlg.cpp: $(FULL_CURRENT_PATH)... expansion and Command::run.
// `variable` returns the value of one Notepad++ variable (FULL_CURRENT_PATH,
// CURRENT_WORD, ...). Returns an error text, or empty on success.
std::string nppRunCommand(const std::string& cmdLine, const std::function<std::string(const std::string&)>& variable);
std::string nppExpandVariables(const std::string& src, const std::function<std::string(const std::string&)>& variable);
