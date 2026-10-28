// Tools > MD5 / SHA-1 / SHA-256 / SHA-512: port of md5Dlgs.cpp (HashFromFilesDlg,
// HashFromTextDlg) and the "Generate from selection into clipboard" commands.
// SHA-1 and SHA-256 come from upstream's sources. Upstream's md5.h declares
// its 32-bit words as `unsigned long`, which is 64-bit on macOS, and
// sha512.cpp uses wincrypt: those two use CommonCrypto.

#import "NppMainWindowInternal.h"
#import "NppRcDialog.h"
#import "NppLocalization.h"

#include <windows.h>
#include <CommonCrypto/CommonDigest.h>

#include "calc_sha1.h"
#include "sha-256.h"
#include "sha512.h"
#include "md5Dlgs_rc.h"
#include "NppUpstream.h"

#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

// sha512.cpp uses wincrypt; same function on CommonCrypto.
void calc_sha_512(unsigned char hash[64], const void* input, size_t len)
{
	CC_SHA512(input, static_cast<CC_LONG>(len), hash);
}

namespace
{
	// hashType: the digest length in bytes, as upstream (hash_md5 = 16, ...).
	enum HashType { hash_md5 = 16, hash_sha1 = 20, hash_sha256 = 32, hash_sha512 = 64 };

	NSString* hashName(HashType t)
	{
		switch (t)
		{
			case hash_md5: return @"MD5";
			case hash_sha1: return @"SHA-1";
			case hash_sha256: return @"SHA-256";
			case hash_sha512: return @"SHA-512";
		}
		return @"";
	}

	std::string digest(HashType t, const std::string& data)
	{
		uint8_t hash[64]{};
		switch (t)
		{
			case hash_md5:
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
				CC_MD5(data.data(), static_cast<CC_LONG>(data.size()), hash);
#pragma clang diagnostic pop
				break;
			case hash_sha1: calc_sha1(hash, data.data(), data.size()); break;
			case hash_sha256: calc_sha_256(hash, data.data(), data.size()); break;
			case hash_sha512: calc_sha_512(hash, data.data(), data.size()); break;
			default: return "";
		}
		std::string out;
		char hex[3];
		for (int i = 0; i < t; ++i)
		{
			snprintf(hex, sizeof(hex), "%02x", hash[i]);
			out += hex;
		}
		return out;
	}

	void toClipboard(NSString* s)
	{
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString: s forType: NSPasteboardTypeString];
	}

	// The result edits use a monospaced font, as upstream sets Courier New.
	void monospace(NppRcDialog* d, int cid)
	{
		NSView* v = [d item: cid];
		if ([v isKindOfClass: NSScrollView.class])
			v = ((NSScrollView*)v).documentView;
		if ([v respondsToSelector: @selector(setFont:)])
			[(id)v setFont: [NSFont monospacedSystemFontOfSize: 11 weight: NSFontWeightRegular]];
	}
}

@interface NppHashDialogs : NSObject
@end

@implementation NppHashDialogs

// HashFromFilesDlg
+ (void)showFromFiles:(HashType)t
{
	static std::unordered_map<int, NppRcDialog*> dialogs;
	NppRcDialog* __strong& dlg = dialogs[t];
	if (!dlg)
	{
		dlg = [[NppRcDialog alloc] initWithRC: @"md5Dlgs.rc" dialog: @"IDD_HASHFROMFILES_DLG"];
		NSString* node = t == hash_md5 ? @"MD5FromFilesDlg" : t == hash_sha1 ? @"SHA1FromFilesDlg" : t == hash_sha256 ? @"SHA256FromFilesDlg" : @"SHA512FromFilesDlg";
		[NppLocalization applyToDialog: dlg node: node];
		dlg.window.title = [NSString stringWithFormat: @"Generate %@ digest from files", hashName(t)];
		[dlg setText: IDC_HASH_FILEBROWSER_BUTTON value: [NSString stringWithFormat: @"Choose files to generate %@...", hashName(t)]];
		monospace(dlg, IDC_HASH_PATH_EDIT);
		monospace(dlg, IDC_HASH_RESULT_EDIT);
		dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
			if (cid == IDC_HASH_FILEBROWSER_BUTTON)
			{
				NSOpenPanel* p = [NSOpenPanel openPanel];
				p.allowsMultipleSelection = YES;
				if ([p runModal] != NSModalResponseOK)
					return YES;
				NSMutableString* files = [NSMutableString string];
				NSMutableString* results = [NSMutableString string];
				for (NSURL* u in p.URLs)
				{
					std::ifstream f(u.fileSystemRepresentation, std::ios::binary);
					if (!f)
						continue;
					std::stringstream ss;
					ss << f.rdbuf();
					// "<digest>  <file name>", like md5sum / sha1sum.
					[files appendFormat: @"%@\n", u.path];
					[results appendFormat: @"%s  %@\n", digest(t, ss.str()).c_str(), u.lastPathComponent];
				}
				[d setText: IDC_HASH_PATH_EDIT value: files];
				[d setText: IDC_HASH_RESULT_EDIT value: results];
				return YES;
			}
			if (cid == IDC_HASH_TOCLIPBOARD_BUTTON)
			{
				NSString* r = [d text: IDC_HASH_RESULT_EDIT];
				if (r.length)
					toClipboard(r);
				return YES;
			}
			return NO;
		};
	}
	[dlg showModeless];
}

// HashFromTextDlg: the digest follows the text as it is typed.
+ (void)showFromText:(HashType)t
{
	static std::unordered_map<int, NppRcDialog*> dialogs;
	NppRcDialog* __strong& dlg = dialogs[t];
	if (!dlg)
	{
		dlg = [[NppRcDialog alloc] initWithRC: @"md5Dlgs.rc" dialog: @"IDD_HASHFROMTEXT_DLG"];
		NSString* node = t == hash_md5 ? @"MD5FromTextDlg" : t == hash_sha1 ? @"SHA1FromTextDlg" : t == hash_sha256 ? @"SHA256FromTextDlg" : @"SHA512FromTextDlg";
		[NppLocalization applyToDialog: dlg node: node];
		dlg.window.title = [NSString stringWithFormat: @"Generate %@ digest", hashName(t)];
		monospace(dlg, IDC_HASH_RESULT_FOMTEXT_EDIT);
		auto update = ^(NppRcDialog* d) {
			std::string text = [d text: IDC_HASH_TEXT_EDIT].UTF8String ?: "";
			if (text.empty())
			{
				[d setText: IDC_HASH_RESULT_FOMTEXT_EDIT value: @""];
				return;
			}
			std::string result;
			if ([d isChecked: IDC_HASH_EACHLINE_CHECK])
			{
				// generateDigestPerLines: empty lines stay empty.
				std::stringstream ss(text);
				std::string line;
				while (std::getline(ss, line))
				{
					if (!line.empty() && line.back() == '\r')
						line.pop_back();
					if (!line.empty())
						result += digest(t, line);
					result += "\n";
				}
			}
			else
				result = digest(t, text);
			[d setText: IDC_HASH_RESULT_FOMTEXT_EDIT value: @(result.c_str())];
		};
		dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
			if (cid == IDC_HASH_TEXT_EDIT || cid == IDC_HASH_EACHLINE_CHECK)
			{
				update(d);
				return YES;
			}
			if (cid == IDC_HASH_FROMTEXT_TOCLIPBOARD_BUTTON)
			{
				NSString* r = [d text: IDC_HASH_RESULT_FOMTEXT_EDIT];
				if (r.length)
					toClipboard(r);
				return YES;
			}
			return NO;
		};
	}
	[dlg showModeless];
}

@end

@implementation NppMainWindow (HashTools)

+ (void)registerHashCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	const struct { HashType type; int text, files, clip; } tools[] = {
		{hash_md5, IDM_TOOL_MD5_GENERATE, IDM_TOOL_MD5_GENERATEFROMFILE, IDM_TOOL_MD5_GENERATEINTOCLIPBOARD},
		{hash_sha1, IDM_TOOL_SHA1_GENERATE, IDM_TOOL_SHA1_GENERATEFROMFILE, IDM_TOOL_SHA1_GENERATEINTOCLIPBOARD},
		{hash_sha256, IDM_TOOL_SHA256_GENERATE, IDM_TOOL_SHA256_GENERATEFROMFILE, IDM_TOOL_SHA256_GENERATEINTOCLIPBOARD},
		{hash_sha512, IDM_TOOL_SHA512_GENERATE, IDM_TOOL_SHA512_GENERATEFROMFILE, IDM_TOOL_SHA512_GENERATEINTOCLIPBOARD},
	};
	for (const auto& tool : tools)
	{
		HashType type = tool.type;
		t[tool.text] = ^(NppMainWindow*) { [NppHashDialogs showFromText: type]; };
		t[tool.files] = ^(NppMainWindow*) { [NppHashDialogs showFromFiles: type]; };
		// Selection (single selection only) -> digest -> clipboard.
		t[tool.clip] = ^(NppMainWindow* w) {
			ScintillaView* e = w.editor;
			if ([e message: SCI_GETSELECTIONS] != 1)
				return;
			long len = [e message: SCI_GETSELECTIONEND] - [e message: SCI_GETSELECTIONSTART];
			if (len <= 0)
				return;
			std::string sel(len + 1, '\0');
			[e message: SCI_GETSELTEXT wParam: 0 lParam: reinterpret_cast<sptr_t>(sel.data())];
			sel.resize(len);
			toClipboard(@(digest(type, sel).c_str()));
		};
	}
}

@end
