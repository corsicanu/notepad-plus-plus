#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#include <CommonCrypto/CommonHMAC.h>

#include "NppShortcuts.h"
#include "NppConfig.h"
#include "NppXml.h"

#include <cstring>
#include <fstream>
#include <sstream>

namespace
{
	const int macroableCommands[] = {
#include "MacroableCommands.inc"
	};

	struct KeyIDNAME { const char* name; unsigned char id; };
	const KeyIDNAME namedKeyArray[] = {
#include "NamedKeys.inc"
	};

	std::string fileContent(const std::string& path)
	{
		std::ifstream f(path, std::ios::binary);
		std::stringstream ss;
		ss << f.rdbuf();
		return ss.str();
	}

	// Stands in for the Windows MachineGuid: the Mac's hardware UUID.
	std::string machineGUID()
	{
		static std::string guid = [] {
			std::string s;
			io_service_t svc = IOServiceGetMatchingService(0 /* kIOMainPortDefault */, IOServiceMatching("IOPlatformExpertDevice"));
			if (svc)
			{
				CFTypeRef uuid = IORegistryEntryCreateCFProperty(svc, CFSTR(kIOPlatformUUIDKey), kCFAllocatorDefault, 0);
				if (uuid)
				{
					s = ((__bridge NSString*)uuid).UTF8String ?: "";
					CFRelease(uuid);
				}
				IOObjectRelease(svc);
			}
			return s;
		}();
		return guid;
	}

	// Port of hmac.h computeHMAC (HMAC-SHA256, lowercase hex).
	std::string computeHMAC(const std::string& key, const std::string& data)
	{
		unsigned char hash[CC_SHA256_DIGEST_LENGTH];
		CCHmac(kCCHmacAlgSHA256, key.data(), key.size(), data.data(), data.size(), hash);
		std::string result;
		char hex[3];
		for (unsigned char b : hash)
		{
			snprintf(hex, sizeof(hex), "%02x", b);
			result += hex;
		}
		return result;
	}

	bool yes(const pugi::xml_node& n, const char* attr)
	{
		return std::strcmp(n.attribute(attr).as_string(), "yes") == 0;
	}

	// Port of NppParameters::getShortcuts.
	bool readEntry(const pugi::xml_node& n, NppShortcutEntry& e)
	{
		const char* name = n.attribute("name").as_string(nullptr);
		if (!name)
			return false;
		e._name = name;
		e._keyCombo._isCtrl = yes(n, "Ctrl");
		e._keyCombo._isAlt = yes(n, "Alt");
		e._keyCombo._isShift = yes(n, "Shift");
		e._keyCombo._key = n.attribute("Key").as_int(0);
		e._folderName = n.attribute("FolderName").as_string("");
		return true;
	}

	void writeEntry(pugi::xml_node n, const NppShortcutEntry& e)
	{
		n.append_attribute("name") = e._name.c_str();
		n.append_attribute("Ctrl") = e._keyCombo._isCtrl ? "yes" : "no";
		n.append_attribute("Alt") = e._keyCombo._isAlt ? "yes" : "no";
		n.append_attribute("Shift") = e._keyCombo._isShift ? "yes" : "no";
		n.append_attribute("Key") = e._keyCombo._key;
	}

	// Port of NppParameters::getActions, including its EOL normalization.
	void readActions(const pugi::xml_node& element, NppMacro& macro)
	{
		for (pugi::xml_node childNode = element.child("Action"); childNode; childNode = childNode.next_sibling("Action"))
		{
			const int type = childNode.attribute("type").as_int(4);
			if (type > 3)
				continue;

			const int msg = childNode.attribute("message").as_int(0);
			const int wParam = childNode.attribute("wParam").as_int(0);
			const int lParam = childNode.attribute("lParam").as_int(0);
			const char* sParam = childNode.attribute("sParam").as_string("");

			const bool isPrevMacroCR = !macro.empty() && macro.back()._message == SCI_REPLACESEL && macro.back()._sParameter == "\r";
			const bool isCR = std::strcmp(sParam, "\r") == 0;

			if (msg == SCI_REPLACESEL && sParam[0] != '\0' && (isCR || std::strcmp(sParam, "\r\n") == 0 || std::strcmp(sParam, "\n") == 0))
			{
				if (isPrevMacroCR)
				{
					if (isCR)
						macro.back() = NppMacroStep(SCI_NEWLINE, 0, 0, nullptr, 0);
					else
						macro.pop_back();
				}
				if (isCR)
					macro.emplace_back(msg, wParam, lParam, sParam, type);
				else
					macro.emplace_back(SCI_NEWLINE, 0, 0, nullptr, 0);
			}
			else
			{
				if (isPrevMacroCR)
					macro.back() = NppMacroStep(SCI_NEWLINE, 0, 0, nullptr, 0);
				macro.emplace_back(msg, wParam, lParam, sParam, type);
			}
		}
		if (!macro.empty() && macro.back()._message == SCI_REPLACESEL && macro.back()._sParameter == "\r")
			macro.back() = NppMacroStep(SCI_NEWLINE, 0, 0, nullptr, 0);
	}

	// Replaces `name` under `root` in place (same position), returning the new node.
	pugi::xml_node replaceChild(pugi::xml_node root, const char* name)
	{
		pugi::xml_node old = root.child(name);
		pugi::xml_node n = old ? root.insert_child_before(name, old) : root.append_child(name);
		if (old)
			root.remove_child(old);
		return n;
	}
}

#pragma mark - NppMacroStep

NppMacroStep::NppMacroStep(int iMessage, uptr_t wParam, uptr_t lParam)
	: _message(iMessage), _wParameter(wParam), _lParameter(lParam), _macroType(mtUseLParameter)
{
	if (_lParameter)
	{
		switch (_message)
		{
			case SCI_SETTEXT:
			case SCI_REPLACESEL:
			case SCI_REPLACETARGET:
			case SCI_REPLACETARGETRE:
			case SCI_SEARCHINTARGET:
			case SCI_ADDTEXT:
			case SCI_ADDSTYLEDTEXT:
			case SCI_INSERTTEXT:
			case SCI_APPENDTEXT:
			case SCI_SETWORDCHARS:
			case SCI_SETWHITESPACECHARS:
			case SCI_SETSTYLINGEX:
			case SCI_TEXTWIDTH:
			case SCI_STYLESETFONT:
			case SCI_SEARCHNEXT:
			case SCI_SEARCHPREV:
			{
				_sParameter = reinterpret_cast<const char*>(_lParameter);
				_macroType = mtUseSParameter;
				_lParameter = 0;
				break;
			}
			default:
				break;
		}
	}
}

// Same list as recordedMacroStep::isMacroable (from Scintilla's Editor::NotifyMacroRecord).
bool NppMacroStep::isMacroable() const
{
	switch (_message)
	{
		case SCI_REPLACESEL:
		case SCI_ADDTEXT:
		case SCI_INSERTTEXT:
		case SCI_APPENDTEXT:
		case SCI_SEARCHNEXT:
		case SCI_SEARCHPREV:
			return _macroType == mtUseSParameter;

		case SCI_GOTOLINE: case SCI_GOTOPOS: case SCI_SETSELECTIONMODE: case SCI_CUT: case SCI_COPY:
		case SCI_PASTE: case SCI_CLEAR: case SCI_CLEARALL: case SCI_SELECTALL: case SCI_SEARCHANCHOR:
		case SCI_LINEDOWN: case SCI_LINEDOWNEXTEND: case SCI_PARADOWN: case SCI_PARADOWNEXTEND:
		case SCI_LINEUP: case SCI_LINEUPEXTEND: case SCI_PARAUP: case SCI_PARAUPEXTEND:
		case SCI_CHARLEFT: case SCI_CHARLEFTEXTEND: case SCI_CHARRIGHT: case SCI_CHARRIGHTEXTEND:
		case SCI_WORDLEFT: case SCI_WORDLEFTEXTEND: case SCI_WORDRIGHT: case SCI_WORDRIGHTEXTEND:
		case SCI_WORDPARTLEFT: case SCI_WORDPARTLEFTEXTEND: case SCI_WORDPARTRIGHT: case SCI_WORDPARTRIGHTEXTEND:
		case SCI_WORDLEFTEND: case SCI_WORDLEFTENDEXTEND: case SCI_WORDRIGHTEND: case SCI_WORDRIGHTENDEXTEND:
		case SCI_HOME: case SCI_HOMEEXTEND: case SCI_LINEEND: case SCI_LINEENDEXTEND:
		case SCI_HOMEWRAP: case SCI_HOMEWRAPEXTEND: case SCI_LINEENDWRAP: case SCI_LINEENDWRAPEXTEND:
		case SCI_DOCUMENTSTART: case SCI_DOCUMENTSTARTEXTEND: case SCI_DOCUMENTEND: case SCI_DOCUMENTENDEXTEND:
		case SCI_STUTTEREDPAGEUP: case SCI_STUTTEREDPAGEUPEXTEND: case SCI_STUTTEREDPAGEDOWN: case SCI_STUTTEREDPAGEDOWNEXTEND:
		case SCI_PAGEUP: case SCI_PAGEUPEXTEND: case SCI_PAGEDOWN: case SCI_PAGEDOWNEXTEND:
		case SCI_EDITTOGGLEOVERTYPE: case SCI_CANCEL: case SCI_DELETEBACK: case SCI_TAB: case SCI_BACKTAB:
		case SCI_FORMFEED: case SCI_VCHOME: case SCI_VCHOMEEXTEND: case SCI_VCHOMEWRAP: case SCI_VCHOMEWRAPEXTEND:
		case SCI_VCHOMEDISPLAY: case SCI_VCHOMEDISPLAYEXTEND: case SCI_DELWORDLEFT: case SCI_DELWORDRIGHT:
		case SCI_DELWORDRIGHTEND: case SCI_DELLINELEFT: case SCI_DELLINERIGHT: case SCI_LINECOPY: case SCI_LINECUT:
		case SCI_LINEDELETE: case SCI_LINETRANSPOSE: case SCI_LINEDUPLICATE: case SCI_LOWERCASE: case SCI_UPPERCASE:
		case SCI_LINESCROLLDOWN: case SCI_LINESCROLLUP: case SCI_DELETEBACKNOTLINE: case SCI_HOMEDISPLAY:
		case SCI_HOMEDISPLAYEXTEND: case SCI_LINEENDDISPLAY: case SCI_LINEENDDISPLAYEXTEND:
		case SCI_LINEDOWNRECTEXTEND: case SCI_LINEUPRECTEXTEND: case SCI_CHARLEFTRECTEXTEND: case SCI_CHARRIGHTRECTEXTEND:
		case SCI_HOMERECTEXTEND: case SCI_VCHOMERECTEXTEND: case SCI_LINEENDRECTEXTEND: case SCI_PAGEUPRECTEXTEND:
		case SCI_PAGEDOWNRECTEXTEND: case SCI_SELECTIONDUPLICATE: case SCI_COPYALLOWLINE: case SCI_VERTICALCENTRECARET:
		case SCI_MOVESELECTEDLINESUP: case SCI_MOVESELECTEDLINESDOWN: case SCI_SCROLLTOSTART: case SCI_SCROLLTOEND:
		case SCI_SETVIRTUALSPACEOPTIONS: case SCI_SETCARETLINEBACKALPHA: case SCI_NEWLINE:
			return _macroType == mtUseLParameter;

		default:
			return false;
	}
}

#pragma mark - shortcuts.xml

NppShortcuts& NppShortcuts::instance()
{
	static NppShortcuts s;
	return s;
}

std::string NppShortcuts::path() const
{
	return NppConfig::instance().userDir() + "/shortcuts.xml";
}

void NppShortcuts::refreshHmac()
{
	_onDiskHmac = computeHMAC(machineGUID(), fileContent(path()));
}

void NppShortcuts::load()
{
	_macros.clear();
	_userCommands.clear();
	std::string p = path();
	if (![NSFileManager.defaultManager fileExistsAtPath: @(p.c_str())])
	{
		std::ofstream(p, std::ios::binary) << SHORTCUT_XML_CONTENT;
		refreshHmac();
		// A freshly generated shortcuts.xml is trusted (NppParameters::load).
		NppConfig::instance().shortcutsXmlHmac = _onDiskHmac;
	}
	else
		refreshHmac();

	pugi::xml_document doc;
	if (!doc.load_file(p.c_str()))
		return;
	pugi::xml_node root = doc.child("NotepadPlus");
	for (pugi::xml_node n = root.child("Macros").child("Macro"); n; n = n.next_sibling("Macro"))
	{
		NppMacroShortcut m;
		if (!readEntry(n, m))
			continue;
		readActions(n, m._macro);
		_macros.push_back(m);
	}
	for (pugi::xml_node n = root.child("UserDefinedCommands").child("Command"); n; n = n.next_sibling("Command"))
	{
		NppUserCommand c;
		if (!readEntry(n, c))
			continue;
		const char* cmd = n.child_value();
		if (!cmd || !*cmd)
			continue;
		c._cmd = cmd;
		_userCommands.push_back(c);
	}
}

bool NppShortcuts::save()
{
	std::string p = path();
	pugi::xml_document doc;
	doc.load_file(p.c_str(), pugi::parse_default | pugi::parse_comments | pugi::parse_declaration);
	pugi::xml_node root = doc.child("NotepadPlus");
	if (!root)
		root = doc.append_child("NotepadPlus");

	pugi::xml_node macrosRoot = replaceChild(root, "Macros");
	for (const auto& m : _macros)
	{
		pugi::xml_node macroRoot = macrosRoot.append_child("Macro");
		writeEntry(macroRoot, m);
		if (!m._folderName.empty())
			macroRoot.append_attribute("FolderName") = m._folderName.c_str();
		for (const auto& a : m._macro)
		{
			pugi::xml_node actionNode = macroRoot.append_child("Action");
			actionNode.append_attribute("type") = static_cast<int>(a._macroType);
			actionNode.append_attribute("message") = a._message;
			actionNode.append_attribute("wParam") = static_cast<unsigned long long>(a._wParameter);
			actionNode.append_attribute("lParam") = static_cast<unsigned long long>(a._lParameter);
			actionNode.append_attribute("sParam") = a._sParameter.c_str();
		}
	}

	pugi::xml_node userCmdRoot = replaceChild(root, "UserDefinedCommands");
	for (const auto& c : _userCommands)
	{
		pugi::xml_node cmdRoot = userCmdRoot.append_child("Command");
		writeEntry(cmdRoot, c);
		cmdRoot.append_child(pugi::node_pcdata).set_value(c._cmd.c_str());
		if (!c._folderName.empty())
			cmdRoot.append_attribute("FolderName") = c._folderName.c_str();
	}

	if (!doc.save_file(p.c_str(), "\t", pugi::format_default, pugi::encoding_utf8))
		return false;
	// Notepad++'s own edits keep the file trusted.
	refreshHmac();
	NppConfig::instance().shortcutsXmlHmac = _onDiskHmac;
	return true;
}

bool NppShortcuts::hmacMissing() const
{
	return NppConfig::instance().shortcutsXmlHmac.empty();
}

bool NppShortcuts::isTrusted() const
{
	const_cast<NppShortcuts*>(this)->refreshHmac();
	return !hmacMissing() && _onDiskHmac == NppConfig::instance().shortcutsXmlHmac;
}

void NppShortcuts::validate()
{
	refreshHmac();
	NppConfig::instance().shortcutsXmlHmac = _onDiskHmac;
}

bool NppShortcuts::isMacroableCommand(int id)
{
	for (int c : macroableCommands)
		if (c == id)
			return true;
	return false;
}

const std::vector<std::pair<std::string, int>>& NppShortcuts::namedKeys()
{
	static std::vector<std::pair<std::string, int>> keys = [] {
		std::vector<std::pair<std::string, int>> k;
		for (const auto& n : namedKeyArray)
			if (n.name[0])
				k.emplace_back(n.name, n.id);
		return k;
	}();
	return keys;
}

std::string NppShortcuts::keyComboString(const NppKeyCombo& k)
{
	if (k._key == 0)
		return "";
	std::string sc;
	if (k._isCtrl)
		sc += "Ctrl+";
	if (k._isAlt)
		sc += "Alt+";
	if (k._isShift)
		sc += "Shift+";
	for (const auto& n : namedKeyArray)
		if (n.id == k._key)
			return sc + n.name;
	return sc;
}

#pragma mark - Run

// Port of expandNppEnvironmentStrs: unknown $(NAME) stays as typed.
std::string nppExpandVariables(const std::string& src, const std::function<std::string(const std::string&)>& variable)
{
	static const char* const known[] = {
		"FULL_CURRENT_PATH", "CURRENT_DIRECTORY", "FILE_NAME", "NAME_PART", "EXT_PART", "CURRENT_WORD",
		"NPP_DIRECTORY", "NPP_FULL_FILE_PATH", "CURRENT_LINE", "CURRENT_COLUMN", "CURRENT_LINESTR",
	};
	std::string out;
	for (size_t i = 0; i < src.size(); ++i)
	{
		if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '(')
		{
			size_t end = src.find(')', i + 2);
			if (end != std::string::npos)
			{
				std::string name = src.substr(i + 2, end - i - 2);
				bool isKnown = false;
				for (const char* k : known)
					isKnown |= name == k;
				if (isKnown)
				{
					out += variable(name);
					i = end;
					continue;
				}
			}
		}
		out += src[i];
	}
	return out;
}

// Port of Command::run: the program is the first (possibly quoted) token,
// the rest are its arguments. URLs and documents open with their default
// application (ShellExecute "open"); anything else runs through the shell.
std::string nppRunCommand(const std::string& cmdLine, const std::function<std::string(const std::string&)>& variable)
{
	// Command::extractArgs
	size_t i = 0;
	bool quoted = false;
	std::string cmdPure;
	for (; i < cmdLine.size(); ++i)
	{
		if (cmdLine[i] == ' ' && !quoted)
			break;
		if (cmdLine[i] == '"')
			quoted = !quoted;
		cmdPure += cmdLine[i];
	}
	while (i < cmdLine.size() && cmdLine[i] == ' ')
		++i;
	std::string args = cmdLine.substr(i);
	while (!args.empty() && args.back() == ' ')
		args.pop_back();

	auto envExpand = [](const std::string& s) {
		// ExpandEnvironmentStrings: %NAME% -> value.
		std::string out;
		for (size_t k = 0; k < s.size(); ++k)
		{
			size_t e;
			if (s[k] == '%' && (e = s.find('%', k + 1)) != std::string::npos)
			{
				const char* v = getenv(s.substr(k + 1, e - k - 1).c_str());
				if (v)
				{
					out += v;
					k = e;
					continue;
				}
			}
			out += s[k];
		}
		return out;
	};
	std::string cmd2Exec = nppExpandVariables(envExpand(cmdPure), variable);
	std::string args2Exec = nppExpandVariables(envExpand(args), variable);

	std::string program = cmd2Exec;
	if (program.size() >= 2 && program.front() == '"' && program.back() == '"')
		program = program.substr(1, program.size() - 2);
	if (program.rfind("~/", 0) == 0)
		program = std::string(NSHomeDirectory().UTF8String) + program.substr(1);

	NSString* prog = @(program.c_str());
	NSURL* url = [NSURL URLWithString: prog];
	BOOL isURL = url.scheme.length > 1 && ![prog hasPrefix: @"/"];
	if (isURL)
	{
		if (![NSWorkspace.sharedWorkspace openURL: url])
			return "Cannot open " + program;
		return "";
	}

	NSFileManager* fm = NSFileManager.defaultManager;
	BOOL isDir = NO;
	BOOL exists = [fm fileExistsAtPath: prog isDirectory: &isDir];
	BOOL isApp = exists && [prog.pathExtension isEqualToString: @"app"];
	if (exists && (isApp || isDir || ![fm isExecutableFileAtPath: prog]))
	{
		// Document, folder or application bundle: open it like Finder does.
		NSURL* fileURL = [NSURL fileURLWithPath: prog];
		if (isApp)
		{
			NSWorkspaceOpenConfiguration* conf = [NSWorkspaceOpenConfiguration configuration];
			if (!args2Exec.empty())
			{
				// Arguments that are files open in the application; the rest are passed through.
				NSMutableArray* files = [NSMutableArray array];
				NSArray* parts = [@(args2Exec.c_str()) componentsSeparatedByString: @" "];
				for (NSString* a in parts)
					if ([fm fileExistsAtPath: a])
						[files addObject: [NSURL fileURLWithPath: a]];
				if (files.count)
				{
					[NSWorkspace.sharedWorkspace openURLs: files withApplicationAtURL: fileURL configuration: conf completionHandler: nil];
					return "";
				}
				conf.arguments = parts;
			}
			[NSWorkspace.sharedWorkspace openApplicationAtURL: fileURL configuration: conf completionHandler: nil];
			return "";
		}
		[NSWorkspace.sharedWorkspace openURL: fileURL];
		return "";
	}

	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath: @"/bin/sh"];
	std::string line = cmd2Exec + (args2Exec.empty() ? "" : " " + args2Exec);
	task.arguments = @[@"-c", @(line.c_str())];
	task.currentDirectoryURL = [NSURL fileURLWithPath: NSHomeDirectory()];
	NSError* err = nil;
	if (![task launchAndReturnError: &err])
	{
		return "An attempt was made to execute the below command.\n----------------------------------------------------------\nCommand: " + cmd2Exec +
		       "\nArguments: " + args2Exec + "\nError: " + (err.localizedDescription.UTF8String ?: "") +
		       "\n----------------------------------------------------------";
	}
	return "";
}
