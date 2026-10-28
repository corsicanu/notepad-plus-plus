// Language > User Defined Language > Define your language...: port of
// UserDefineDialog with its four pages (FolderStyleDialog, KeyWordsStyleDialog,
// CommentStyleDialog, SymbolsStyleDialog), StylerDlg and StringDlg, built
// from upstream's UserDefineDialog.rc.

#import "NppMainWindowInternal.h"
#import "NppRcDialog.h"
#import "NppLocalization.h"

#include "NppUdl.h"
#include "NppUpstream.h"
#include "UserDefineResource.h"
#include "ILexer.h"
#include "SciLexer.h"

#include <unordered_map>

typedef void (^NppCommandHandler)(NppMainWindow* w);

@interface NppMainWindow (UdlDialogHost)
+ (void)installUserLangItemsIn:(NSMenu*)bar;
@end

namespace
{
	// Parameters.h
	constexpr int PURE_LC_NONE = 0, PURE_LC_BOL = 1, PURE_LC_WSP = 2;
	constexpr size_t kMaxChar = 1024 * 30;

	const int kCommentEdits[] = {
		IDC_COMMENTLINE_OPEN_EDIT, IDC_COMMENTLINE_CONTINUE_EDIT, IDC_COMMENTLINE_CLOSE_EDIT,
		IDC_COMMENT_OPEN_EDIT, IDC_COMMENT_CLOSE_EDIT,
	};
	const int kDelimiterEdits[] = {
		IDC_DELIMITER1_BOUNDARYOPEN_EDIT, IDC_DELIMITER1_ESCAPE_EDIT, IDC_DELIMITER1_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER2_BOUNDARYOPEN_EDIT, IDC_DELIMITER2_ESCAPE_EDIT, IDC_DELIMITER2_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER3_BOUNDARYOPEN_EDIT, IDC_DELIMITER3_ESCAPE_EDIT, IDC_DELIMITER3_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER4_BOUNDARYOPEN_EDIT, IDC_DELIMITER4_ESCAPE_EDIT, IDC_DELIMITER4_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER5_BOUNDARYOPEN_EDIT, IDC_DELIMITER5_ESCAPE_EDIT, IDC_DELIMITER5_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER6_BOUNDARYOPEN_EDIT, IDC_DELIMITER6_ESCAPE_EDIT, IDC_DELIMITER6_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER7_BOUNDARYOPEN_EDIT, IDC_DELIMITER7_ESCAPE_EDIT, IDC_DELIMITER7_BOUNDARYCLOSE_EDIT,
		IDC_DELIMITER8_BOUNDARYOPEN_EDIT, IDC_DELIMITER8_ESCAPE_EDIT, IDC_DELIMITER8_BOUNDARYCLOSE_EDIT,
	};
	// Edits stored as-is in one keyword list (GlobalMappers::dialogMapper).
	const std::pair<int, int> kPlainEdits[] = {
		{IDC_NUMBER_PREFIX1_EDIT, SCE_USER_KWLIST_NUMBER_PREFIX1}, {IDC_NUMBER_PREFIX2_EDIT, SCE_USER_KWLIST_NUMBER_PREFIX2},
		{IDC_NUMBER_EXTRAS1_EDIT, SCE_USER_KWLIST_NUMBER_EXTRAS1}, {IDC_NUMBER_EXTRAS2_EDIT, SCE_USER_KWLIST_NUMBER_EXTRAS2},
		{IDC_NUMBER_SUFFIX1_EDIT, SCE_USER_KWLIST_NUMBER_SUFFIX1}, {IDC_NUMBER_SUFFIX2_EDIT, SCE_USER_KWLIST_NUMBER_SUFFIX2},
		{IDC_NUMBER_RANGE_EDIT, SCE_USER_KWLIST_NUMBER_RANGE},
		{IDC_FOLDER_IN_CODE1_OPEN_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE1_OPEN}, {IDC_FOLDER_IN_CODE1_MIDDLE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE1_MIDDLE},
		{IDC_FOLDER_IN_CODE1_CLOSE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE1_CLOSE},
		{IDC_FOLDER_IN_CODE2_OPEN_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE2_OPEN}, {IDC_FOLDER_IN_CODE2_MIDDLE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE2_MIDDLE},
		{IDC_FOLDER_IN_CODE2_CLOSE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_CODE2_CLOSE},
		{IDC_FOLDER_IN_COMMENT_OPEN_EDIT, SCE_USER_KWLIST_FOLDERS_IN_COMMENT_OPEN}, {IDC_FOLDER_IN_COMMENT_MIDDLE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_COMMENT_MIDDLE},
		{IDC_FOLDER_IN_COMMENT_CLOSE_EDIT, SCE_USER_KWLIST_FOLDERS_IN_COMMENT_CLOSE},
		{IDC_KEYWORD1_EDIT, SCE_USER_KWLIST_KEYWORDS1}, {IDC_KEYWORD2_EDIT, SCE_USER_KWLIST_KEYWORDS2},
		{IDC_KEYWORD3_EDIT, SCE_USER_KWLIST_KEYWORDS3}, {IDC_KEYWORD4_EDIT, SCE_USER_KWLIST_KEYWORDS4},
		{IDC_KEYWORD5_EDIT, SCE_USER_KWLIST_KEYWORDS5}, {IDC_KEYWORD6_EDIT, SCE_USER_KWLIST_KEYWORDS6},
		{IDC_KEYWORD7_EDIT, SCE_USER_KWLIST_KEYWORDS7}, {IDC_KEYWORD8_EDIT, SCE_USER_KWLIST_KEYWORDS8},
		{IDC_OPERATOR1_EDIT, SCE_USER_KWLIST_OPERATORS1}, {IDC_OPERATOR2_EDIT, SCE_USER_KWLIST_OPERATORS2},
	};
	const int kPrefixChecks[] = {
		IDC_KEYWORD1_PREFIX_CHECK, IDC_KEYWORD2_PREFIX_CHECK, IDC_KEYWORD3_PREFIX_CHECK, IDC_KEYWORD4_PREFIX_CHECK,
		IDC_KEYWORD5_PREFIX_CHECK, IDC_KEYWORD6_PREFIX_CHECK, IDC_KEYWORD7_PREFIX_CHECK, IDC_KEYWORD8_PREFIX_CHECK,
	};
	// Styler buttons: style and the nesting choices offered (-1 = all).
	struct StylerButton { int ctrl; int style; int nesters; };
	const StylerButton kStylers[] = {
		{IDC_DEFAULT_STYLER, SCE_USER_STYLE_DEFAULT, SCE_USER_MASK_NESTING_NONE},
		{IDC_FOLDER_IN_CODE1_STYLER, SCE_USER_STYLE_FOLDER_IN_CODE1, SCE_USER_MASK_NESTING_NONE},
		{IDC_FOLDER_IN_CODE2_STYLER, SCE_USER_STYLE_FOLDER_IN_CODE2, SCE_USER_MASK_NESTING_NONE},
		{IDC_FOLDER_IN_COMMENT_STYLER, SCE_USER_STYLE_FOLDER_IN_COMMENT, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD1_STYLER, SCE_USER_STYLE_KEYWORD1, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD2_STYLER, SCE_USER_STYLE_KEYWORD2, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD3_STYLER, SCE_USER_STYLE_KEYWORD3, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD4_STYLER, SCE_USER_STYLE_KEYWORD4, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD5_STYLER, SCE_USER_STYLE_KEYWORD5, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD6_STYLER, SCE_USER_STYLE_KEYWORD6, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD7_STYLER, SCE_USER_STYLE_KEYWORD7, SCE_USER_MASK_NESTING_NONE},
		{IDC_KEYWORD8_STYLER, SCE_USER_STYLE_KEYWORD8, SCE_USER_MASK_NESTING_NONE},
		{IDC_COMMENTLINE_STYLER, SCE_USER_STYLE_COMMENTLINE, -1},
		{IDC_COMMENT_STYLER, SCE_USER_STYLE_COMMENT, -1},
		{IDC_NUMBER_STYLER, SCE_USER_STYLE_NUMBER, SCE_USER_MASK_NESTING_NONE},
		{IDC_OPERATOR_STYLER, SCE_USER_STYLE_OPERATOR, SCE_USER_MASK_NESTING_NONE},
		{IDC_DELIMITER1_STYLER, SCE_USER_STYLE_DELIMITER1, -1}, {IDC_DELIMITER2_STYLER, SCE_USER_STYLE_DELIMITER2, -1},
		{IDC_DELIMITER3_STYLER, SCE_USER_STYLE_DELIMITER3, -1}, {IDC_DELIMITER4_STYLER, SCE_USER_STYLE_DELIMITER4, -1},
		{IDC_DELIMITER5_STYLER, SCE_USER_STYLE_DELIMITER5, -1}, {IDC_DELIMITER6_STYLER, SCE_USER_STYLE_DELIMITER6, -1},
		{IDC_DELIMITER7_STYLER, SCE_USER_STYLE_DELIMITER7, -1}, {IDC_DELIMITER8_STYLER, SCE_USER_STYLE_DELIMITER8, -1},
	};
	// StylerDlg nesting check boxes (GlobalMappers::nestingMapper).
	const std::pair<int, int> kNesting[] = {
		{IDC_STYLER_CHECK_NESTING_DELIMITER1, SCE_USER_MASK_NESTING_DELIMITER1}, {IDC_STYLER_CHECK_NESTING_DELIMITER2, SCE_USER_MASK_NESTING_DELIMITER2},
		{IDC_STYLER_CHECK_NESTING_DELIMITER3, SCE_USER_MASK_NESTING_DELIMITER3}, {IDC_STYLER_CHECK_NESTING_DELIMITER4, SCE_USER_MASK_NESTING_DELIMITER4},
		{IDC_STYLER_CHECK_NESTING_DELIMITER5, SCE_USER_MASK_NESTING_DELIMITER5}, {IDC_STYLER_CHECK_NESTING_DELIMITER6, SCE_USER_MASK_NESTING_DELIMITER6},
		{IDC_STYLER_CHECK_NESTING_DELIMITER7, SCE_USER_MASK_NESTING_DELIMITER7}, {IDC_STYLER_CHECK_NESTING_DELIMITER8, SCE_USER_MASK_NESTING_DELIMITER8},
		{IDC_STYLER_CHECK_NESTING_COMMENT, SCE_USER_MASK_NESTING_COMMENT}, {IDC_STYLER_CHECK_NESTING_COMMENT_LINE, SCE_USER_MASK_NESTING_COMMENT_LINE},
		{IDC_STYLER_CHECK_NESTING_KEYWORD1, SCE_USER_MASK_NESTING_KEYWORD1}, {IDC_STYLER_CHECK_NESTING_KEYWORD2, SCE_USER_MASK_NESTING_KEYWORD2},
		{IDC_STYLER_CHECK_NESTING_KEYWORD3, SCE_USER_MASK_NESTING_KEYWORD3}, {IDC_STYLER_CHECK_NESTING_KEYWORD4, SCE_USER_MASK_NESTING_KEYWORD4},
		{IDC_STYLER_CHECK_NESTING_KEYWORD5, SCE_USER_MASK_NESTING_KEYWORD5}, {IDC_STYLER_CHECK_NESTING_KEYWORD6, SCE_USER_MASK_NESTING_KEYWORD6},
		{IDC_STYLER_CHECK_NESTING_KEYWORD7, SCE_USER_MASK_NESTING_KEYWORD7}, {IDC_STYLER_CHECK_NESTING_KEYWORD8, SCE_USER_MASK_NESTING_KEYWORD8},
		{IDC_STYLER_CHECK_NESTING_OPERATORS1, SCE_USER_MASK_NESTING_OPERATORS1}, {IDC_STYLER_CHECK_NESTING_OPERATORS2, SCE_USER_MASK_NESTING_OPERATORS2},
		{IDC_STYLER_CHECK_NESTING_NUMBERS, SCE_USER_MASK_NESTING_NUMBERS},
	};

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

	std::string str(NSString* s)
	{
		return s.UTF8String ?: "";
	}

	// UserDefineDialog.cpp convertTo: each space-separated item gets the
	// two-character prefix; "((...))" groups keep their inner spaces.
	void convertTo(std::string& dest, const std::string& toConvert, const char prefix[2])
	{
		bool inGroup = false;
		if (!dest.empty())
			dest += ' ';
		dest += prefix[0];
		dest += prefix[1];
		auto at = [&](size_t i) { return i < toConvert.size() ? toConvert[i] : '\0'; };
		for (size_t i = 0, len = toConvert.size(); i < len && dest.size() < kMaxChar - 7; ++i)
		{
			if (i == 0 && at(i) == '(' && at(i + 1) == '(')
				inGroup = true;
			else if (at(i) == ' ' && at(i + 1) == '(' && at(i + 2) == '(')
			{
				inGroup = true;
				dest += ' ';
				dest += prefix[0];
				dest += prefix[1];
				++i;
			}
			if (inGroup && i >= 2 && at(i - 1) == ')' && at(i - 2) == ')')
				inGroup = false;
			if (at(i) == ' ')
			{
				if (at(i + 1) != ' ' && at(i + 1) != '\0')
				{
					dest += ' ';
					if (!inGroup)
					{
						dest += prefix[0];
						dest += prefix[1];
					}
				}
			}
			else
				dest += at(i);
		}
	}

	// CommentStyleDialog / SymbolsStyleDialog::retrieve: the items of one prefix.
	std::string retrieve(const std::string& toRetrieve, const char prefix[2])
	{
		std::string dest;
		bool begin2Copy = false, inGroup = false;
		auto at = [&](size_t i) { return i < toRetrieve.size() ? toRetrieve[i] : '\0'; };
		for (size_t i = 0, len = toRetrieve.size(); i < len; ++i)
		{
			if ((i == 0 || at(i - 1) == ' ') && at(i) == prefix[0] && at(i + 1) == prefix[1])
			{
				if (!dest.empty())
					dest += ' ';
				begin2Copy = true;
				++i;
				continue;
			}
			if (at(i) == '(' && at(i + 1) == '(' && !inGroup && begin2Copy)
				inGroup = true;
			if (i >= 2 && at(i) != ')' && at(i - 1) == ')' && at(i - 2) == ')' && inGroup)
				inGroup = false;
			if (at(i) == ' ' && begin2Copy)
				begin2Copy = false;
			if (begin2Copy || inGroup)
				dest += at(i);
		}
		return dest;
	}

	void prefixFor(int i, char out[3])
	{
		snprintf(out, 3, "%02d", i);
	}

	// StringDlg (IDD_STRING_DLG): one line of text.
	NSString* askString(NSString* title, NSString* label, NSString* initial)
	{
		NppRcDialog* d = [[NppRcDialog alloc] initWithRC: @"UserDefineDialog.rc" dialog: @"IDD_STRING_DLG"];
		d.window.title = title;
		[d setText: IDC_STRING_STATIC value: label];
		[d setText: IDC_STRING_EDIT value: initial ?: @""];
		if ([d runModal] != IDOK)
			return nil;
		NSString* s = [[d text: IDC_STRING_EDIT] stringByTrimmingCharactersInSet: NSCharacterSet.whitespaceCharacterSet];
		return s.length ? s : nil;
	}

	void message(NSString* text)
	{
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = text;
		[a runModal];
	}
}

@interface NppUdlDialog : NSObject
+ (instancetype)shared;
- (void)showForWindow:(NppMainWindow*)window;
@end

@implementation NppUdlDialog
{
	__weak NppMainWindow* _window;
	NppRcDialog* _dlg;
	NSSegmentedControl* _tabs;
	NSMutableArray<NSView*>* _pages;
	std::unique_ptr<NppUserLang> _generic;    // "User Defined Language" (index 0), not saved
	NppUserLang* _lang;
	BOOL _loading;
}

+ (instancetype)shared
{
	static NppUdlDialog* d = [[NppUdlDialog alloc] init];
	return d;
}

- (void)showForWindow:(NppMainWindow*)window
{
	_window = window;
	if (!_dlg)
		[self build];
	[self reloadLangCombo];
	// Open on the current document's UDL, like the docked dialog follows the view.
	NSInteger sel = 0;
	if (NSString* cur = window.currentBuffer.userLangName)
	{
		const auto& langs = NppUdlManager::instance().languages();
		for (size_t i = 0; i < langs.size(); ++i)
			if (langs[i]->name == cur.UTF8String)
				sel = i + 1;
	}
	[_dlg select: sel inList: IDC_LANGNAME_COMBO];
	[self enableLangAndControlsBy: sel];
	[self updateDlg];
	[_dlg showModeless];
}

- (void)build
{
	_generic = NppUserLang::makeNew("User Defined Language");
	_dlg = [[NppRcDialog alloc] initWithRC: @"UserDefineDialog.rc" dialog: @"IDD_GLOBAL_USERDEFINE_DLG"];
	NSView* root = _dlg.window.contentView;

	// The four pages under a tab bar (upstream's _ctrlTab), scrolled as one.
	NSArray* pageIds = @[@"IDD_FOLDER_STYLE_DLG", @"IDD_KEYWORD_STYLE_DLG", @"IDD_COMMENT_STYLE_DLG", @"IDD_SYMBOL_STYLE_DLG"];
	NSArray* titles = @[@"Folder & Default", @"Keywords Lists", @"Comment & Number", @"Operators & Delimiters"];
	CGFloat top = 40 * 1.85;
	_tabs = [NSSegmentedControl segmentedControlWithLabels: titles trackingMode: NSSegmentSwitchTrackingSelectOne target: self action: @selector(tabChanged:)];
	[_tabs sizeToFit];
	_tabs.frame = NSMakeRect((root.bounds.size.width - _tabs.frame.size.width) / 2, top, _tabs.frame.size.width, _tabs.frame.size.height);
	_tabs.selectedSegment = 0;
	[root addSubview: _tabs];

	NSRect area = NSMakeRect(0, NSMaxY(_tabs.frame) + 6, root.bounds.size.width, root.bounds.size.height - NSMaxY(_tabs.frame) - 6);
	_pages = [NSMutableArray array];
	for (NSString* idd in pageIds)
	{
		NSView* page = [NppRcDialog viewFromRC: @"UserDefineDialog.rc" dialog: idd owner: _dlg];
		NSView* doc = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, area.size.width, page.frame.size.height + 10)];
		page.frame = NSMakeRect((area.size.width - page.frame.size.width) / 2, 0, page.frame.size.width, page.frame.size.height);
		[doc addSubview: page];
		NSScrollView* sv = [[NSScrollView alloc] initWithFrame: area];
		sv.hasVerticalScroller = YES;
		sv.autohidesScrollers = YES;
		sv.drawsBackground = NO;
		sv.documentView = doc;
		sv.hidden = YES;
		[root addSubview: sv];
		[_pages addObject: sv];
	}
	((NSView*)_pages[0]).hidden = NO;

	// Dock / transparency are window-docking features of the Win32 dialog.
	[_dlg show: IDC_DOCK_BUTTON value: NO];

	[NppLocalization applyToDialog: _dlg node: @"UserDefine"];
	__weak NppUdlDialog* weakSelf = self;
	_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) { return [weakSelf command: cid]; };
}

- (void)tabChanged:(id)sender
{
	for (NSUInteger i = 0; i < _pages.count; ++i)
		((NSView*)_pages[i]).hidden = (NSInteger)i != _tabs.selectedSegment;
}

- (void)reloadLangCombo
{
	NSMutableArray* names = [NSMutableArray arrayWithObject: @"User Defined Language"];
	for (const auto& l : NppUdlManager::instance().languages())
		[names addObject: ns(l->name)];
	[_dlg setItems: names forList: IDC_LANGNAME_COMBO];
}

// UserDefineDialog::enableLangAndControlsBy
- (void)enableLangAndControlsBy:(NSInteger)index
{
	const auto& langs = NppUdlManager::instance().languages();
	_lang = (index <= 0 || index > (NSInteger)langs.size()) ? _generic.get() : langs[index - 1].get();
	BOOL real = _lang != _generic.get();
	if (real)
		[_dlg setText: IDC_EXT_EDIT value: ns(_lang->ext)];
	for (int cid : {IDC_EXT_STATIC, IDC_EXT_EDIT, IDC_RENAME_BUTTON, IDC_REMOVELANG_BUTTON})
		[_dlg show: cid value: real];
}

// updateDlg of the main dialog and the four pages.
- (void)updateDlg
{
	_loading = YES;
	NppUserLang& ul = *_lang;
	[_dlg setChecked: IDC_LANGNAME_IGNORECASE_CHECK value: ul.isCaseIgnored];
	[_dlg setChecked: IDC_FOLDER_FOLD_COMPACT value: ul.foldCompact];
	for (const auto& [cid, kw] : kPlainEdits)
		[_dlg setText: cid value: ns(ul.keywordLists[kw])];
	for (int i = 0; i < 8; ++i)
		[_dlg setChecked: kPrefixChecks[i] value: ul.isPrefix[i]];
	char prefix[3];
	for (int i = 0; i < 5; ++i)
	{
		prefixFor(i, prefix);
		[_dlg setText: kCommentEdits[i] value: ns(retrieve(ul.keywordLists[SCE_USER_KWLIST_COMMENTS], prefix))];
	}
	for (int i = 0; i < 24; ++i)
	{
		prefixFor(i, prefix);
		[_dlg setText: kDelimiterEdits[i] value: ns(retrieve(ul.keywordLists[SCE_USER_KWLIST_DELIMITERS], prefix))];
	}
	[_dlg setChecked: IDC_FOLDING_OF_COMMENTS value: ul.allowFoldOfComments];
	[_dlg setChecked: IDC_ALLOW_ANYWHERE value: ul.forcePureLC == PURE_LC_NONE];
	[_dlg setChecked: IDC_FORCE_AT_BOL value: ul.forcePureLC == PURE_LC_BOL];
	[_dlg setChecked: IDC_ALLOW_WHITESPACE value: ul.forcePureLC == PURE_LC_WSP];
	[_dlg setChecked: IDC_DOT_RADIO value: ul.decimalSeparator == DECSEP_DOT];
	[_dlg setChecked: IDC_COMMA_RADIO value: ul.decimalSeparator == DECSEP_COMMA];
	[_dlg setChecked: IDC_BOTH_RADIO value: ul.decimalSeparator == DECSEP_BOTH];
	_loading = NO;
}

// The language changed: saved later, and every document using it is restyled
// (SharedParametersDialog -> ScintillaEditView::styleChange).
- (void)changed
{
	if (_lang != _generic.get())
		NppUdlManager::instance().markDirty(_lang);
	if (NppMainWindow* w = _window)
		[w restyleUserLang: ns(_lang->name)];
}

- (BOOL)command:(int)cid
{
	if (_loading)
		return YES;
	NppUserLang& ul = *_lang;
	NppUdlManager& mgr = NppUdlManager::instance();

	for (const auto& [ctrl, kw] : kPlainEdits)
		if (ctrl == cid)
		{
			ul.keywordLists[kw] = str([_dlg text: cid]);
			[self changed];
			return YES;
		}
	for (int c : kCommentEdits)
		if (c == cid)
		{
			std::string list;
			char prefix[3];
			for (int i = 0; i < 5; ++i)
			{
				prefixFor(i, prefix);
				convertTo(list, str([_dlg text: kCommentEdits[i]]), prefix);
			}
			ul.keywordLists[SCE_USER_KWLIST_COMMENTS] = list;
			[self changed];
			return YES;
		}
	for (int c : kDelimiterEdits)
		if (c == cid)
		{
			std::string list;
			char prefix[3];
			for (int i = 0; i < 24; ++i)
			{
				prefixFor(i, prefix);
				convertTo(list, str([_dlg text: kDelimiterEdits[i]]), prefix);
			}
			ul.keywordLists[SCE_USER_KWLIST_DELIMITERS] = list;
			[self changed];
			return YES;
		}
	for (int i = 0; i < 8; ++i)
		if (kPrefixChecks[i] == cid)
		{
			ul.isPrefix[i] = [_dlg isChecked: cid];
			[self changed];
			return YES;
		}
	for (const StylerButton& s : kStylers)
		if (s.ctrl == cid)
		{
			[self styler: s.style nesters: s.nesters];
			return YES;
		}

	switch (cid)
	{
		case IDC_LANGNAME_COMBO:
			[self enableLangAndControlsBy: [_dlg selectedIndex: cid]];
			[self updateDlg];
			return YES;
		case IDC_LANGNAME_IGNORECASE_CHECK: ul.isCaseIgnored = [_dlg isChecked: cid]; [self changed]; return YES;
		case IDC_FOLDER_FOLD_COMPACT: ul.foldCompact = [_dlg isChecked: cid]; [self changed]; return YES;
		case IDC_FOLDING_OF_COMMENTS: ul.allowFoldOfComments = [_dlg isChecked: cid]; [self changed]; return YES;
		case IDC_ALLOW_ANYWHERE:
		case IDC_FORCE_AT_BOL:
		case IDC_ALLOW_WHITESPACE:
			ul.forcePureLC = [_dlg isChecked: IDC_FORCE_AT_BOL] ? PURE_LC_BOL : [_dlg isChecked: IDC_ALLOW_WHITESPACE] ? PURE_LC_WSP : PURE_LC_NONE;
			[self changed];
			return YES;
		case IDC_DOT_RADIO:
		case IDC_COMMA_RADIO:
		case IDC_BOTH_RADIO:
			ul.decimalSeparator = [_dlg isChecked: IDC_COMMA_RADIO] ? DECSEP_COMMA : [_dlg isChecked: IDC_BOTH_RADIO] ? DECSEP_BOTH : DECSEP_DOT;
			[self changed];
			return YES;
		case IDC_EXT_EDIT:
			ul.ext = str([_dlg text: cid]);
			[self changed];
			return YES;
		case IDC_WEB_HELP_LINK:
			[NSWorkspace.sharedWorkspace openURL: [NSURL URLWithString: @"https://npp-user-manual.org/docs/user-defined-language-system/"]];
			return YES;

		case IDC_ADDNEW_BUTTON:
		case IDC_SAVEAS_BUTTON:
		{
			BOOL saveAs = cid == IDC_SAVEAS_BUTTON && _lang != _generic.get();
			NSString* name = askString(saveAs ? @"Save Current Language Name As..." : @"Create New Language...", @"Name", @"");
			if (!name)
				return YES;
			if (mgr.byName(str(name)))
			{
				message(@"This name is used by another language,\nplease give another one.");
				return YES;
			}
			std::unique_ptr<NppUserLang> copy = std::make_unique<NppUserLang>(saveAs ? *_lang : *_generic);
			copy->name = str(name);
			copy->file.clear();
			mgr.add(std::move(copy));
			mgr.save();
			[self afterListChange: mgr.languages().size()];
			return YES;
		}
		case IDC_RENAME_BUTTON:
		{
			NSString* oldName = ns(ul.name);
			NSString* name = askString(@"Rename Current Language Name", @"Name", oldName);
			if (!name || [name isEqualToString: oldName])
				return YES;
			if (!mgr.rename(_lang, str(name)))
			{
				message(@"This name is used by another language,\nplease give another one.");
				return YES;
			}
			mgr.save();
			if (NppMainWindow* w = _window)
				[w renameUserLang: oldName to: name];
			[self afterListChange: [_dlg selectedIndex: IDC_LANGNAME_COMBO]];
			return YES;
		}
		case IDC_REMOVELANG_BUTTON:
		{
			NSAlert* a = [[NSAlert alloc] init];
			a.messageText = @"Remove the current language";
			a.informativeText = @"Are you sure?";
			[a addButtonWithTitle: @"Yes"];
			[a addButtonWithTitle: @"No"];
			if ([a runModal] != NSAlertFirstButtonReturn)
				return YES;
			NSString* name = ns(ul.name);
			NSInteger idx = [_dlg selectedIndex: IDC_LANGNAME_COMBO];
			mgr.remove(_lang);
			_lang = _generic.get();
			mgr.save();
			if (NppMainWindow* w = _window)
				[w renameUserLang: name to: nil];
			[self afterListChange: idx - 1];
			return YES;
		}
		case IDC_IMPORT_BUTTON:
		{
			NSOpenPanel* p = [NSOpenPanel openPanel];
			if ([p runModal] != NSModalResponseOK)
				return YES;
			NSInteger idx = [_dlg selectedIndex: IDC_LANGNAME_COMBO];
			if (mgr.importFile(p.URL.fileSystemRepresentation) > 0)
			{
				mgr.save();
				[self afterListChange: idx];
				message(@"Import successful.");
			}
			else
				message(@"Failed to import.");
			return YES;
		}
		case IDC_EXPORT_BUTTON:
		{
			if (_lang == _generic.get())
			{
				message(@"Before exporting, save your language definition by clicking \"Save as...\" button");
				return YES;
			}
			NSSavePanel* p = [NSSavePanel savePanel];
			p.nameFieldStringValue = [ns(ul.name) stringByAppendingPathExtension: @"xml"];
			if ([p runModal] != NSModalResponseOK)
				return YES;
			message(mgr.exportLang(_lang, p.URL.fileSystemRepresentation) ? @"Export successful" : @"Failed to export.");
			return YES;
		}
		case IDCANCEL:
			mgr.save();
			[_dlg endWith: IDCANCEL];
			return YES;
	}
	return NO;
}

// Combo, Language menu and the open documents follow a list change.
- (void)afterListChange:(NSInteger)select
{
	[self reloadLangCombo];
	[_dlg select: select inList: IDC_LANGNAME_COMBO];
	[self enableLangAndControlsBy: select];
	[self updateDlg];
	[NppMainWindow installUserLangItemsIn: NSApp.mainMenu];
}

#pragma mark StylerDlg

- (void)styler:(int)styleID nesters:(int)enabledNesters
{
	NppUdlStyle* stp = _lang->style(styleID);
	if (!stp)
		return;
	NppUdlStyle initial = *stp;
	NppUdlStyle& style = *stp;

	NppRcDialog* d = [[NppRcDialog alloc] initWithRC: @"UserDefineDialog.rc" dialog: @"IDD_STYLER_POPUP_DLG"];
	[NppLocalization applyToDialog: d node: @"StylerDialog"];

	// Font names (blank = default) and sizes (fontSizeStrs).
	NSArray* fonts = [@[@""] arrayByAddingObjectsFromArray:
		[NSFontManager.sharedFontManager.availableFontFamilies sortedArrayUsingSelector: @selector(localizedCaseInsensitiveCompare:)]];
	[d setItems: fonts forList: IDC_STYLER_COMBO_FONT_NAME];
	NSUInteger fi = [fonts indexOfObject: ns(style.fontName)];
	[d select: fi == NSNotFound ? 0 : fi inList: IDC_STYLER_COMBO_FONT_NAME];
	NSArray* sizes = @[@"", @"5", @"6", @"7", @"8", @"9", @"10", @"11", @"12", @"14", @"16", @"18", @"20", @"22", @"24", @"26", @"28"];
	[d setItems: sizes forList: IDC_STYLER_COMBO_FONT_SIZE];
	NSUInteger si = style.fontSize > 0 ? [sizes indexOfObject: [NSString stringWithFormat: @"%d", style.fontSize]] : 0;
	[d select: si == NSNotFound ? 0 : si inList: IDC_STYLER_COMBO_FONT_SIZE];

	int sfs = style.fontStyle == -1 ? 0 : style.fontStyle;
	[d setChecked: IDC_STYLER_CHECK_BOLD value: (sfs & FONTSTYLE_BOLD) != 0];
	[d setChecked: IDC_STYLER_CHECK_ITALIC value: (sfs & FONTSTYLE_ITALIC) != 0];
	[d setChecked: IDC_STYLER_CHECK_UNDERLINE value: (sfs & FONTSTYLE_UNDERLINE) != 0];

	// Colour pickers next to the labels (ColourPicker).
	auto colorWell = ^NSColorWell*(int labelId, int rgb) {
		NSView* label = [d item: labelId];
		NSColorWell* w = [[NSColorWell alloc] initWithFrame: NSMakeRect(NSMaxX(label.frame) + 6, label.frame.origin.y - 4, 34, 22)];
		w.color = [NSColor colorWithSRGBRed: ((rgb >> 16) & 0xFF) / 255.0 green: ((rgb >> 8) & 0xFF) / 255.0 blue: (rgb & 0xFF) / 255.0 alpha: 1];
		[label.superview addSubview: w];
		return w;
	};
	NSColorWell* fg = colorWell(IDC_STYLER_FG_STATIC, style.fgColor >= 0 ? style.fgColor : 0x000000);
	NSColorWell* bg = colorWell(IDC_STYLER_BG_STATIC, style.bgColor >= 0 ? style.bgColor : 0xFFFFFF);
	[d setChecked: IDC_STYLER_CHECK_FG_TRANSPARENT value: !(style.colorStyle & COLORSTYLE_FOREGROUND)];
	[d setChecked: IDC_STYLER_CHECK_BG_TRANSPARENT value: !(style.colorStyle & COLORSTYLE_BACKGROUND)];
	fg.enabled = (style.colorStyle & COLORSTYLE_FOREGROUND) != 0;
	bg.enabled = (style.colorStyle & COLORSTYLE_BACKGROUND) != 0;

	for (const auto& [ctrl, mask] : kNesting)
	{
		[d setChecked: ctrl value: (style.nesting & mask) != 0];
		[d enable: ctrl value: (enabledNesters & mask) != 0];
	}

	__weak NppUdlDialog* weakSelf = self;
	auto readBack = ^{
		auto rgb = [](NSColor* c) {
			NSColor* s = [c colorUsingColorSpace: NSColorSpace.sRGBColorSpace];
			return (int(s.redComponent * 255 + 0.5) << 16) | (int(s.greenComponent * 255 + 0.5) << 8) | int(s.blueComponent * 255 + 0.5);
		};
		style.fgColor = rgb(fg.color);
		style.bgColor = rgb(bg.color);
		style.colorStyle = ([d isChecked: IDC_STYLER_CHECK_FG_TRANSPARENT] ? 0 : COLORSTYLE_FOREGROUND) |
		                   ([d isChecked: IDC_STYLER_CHECK_BG_TRANSPARENT] ? 0 : COLORSTYLE_BACKGROUND);
		fg.enabled = (style.colorStyle & COLORSTYLE_FOREGROUND) != 0;
		bg.enabled = (style.colorStyle & COLORSTYLE_BACKGROUND) != 0;
		style.fontStyle = ([d isChecked: IDC_STYLER_CHECK_BOLD] ? FONTSTYLE_BOLD : 0) |
		                  ([d isChecked: IDC_STYLER_CHECK_ITALIC] ? FONTSTYLE_ITALIC : 0) |
		                  ([d isChecked: IDC_STYLER_CHECK_UNDERLINE] ? FONTSTYLE_UNDERLINE : 0);
		NSInteger f = [d selectedIndex: IDC_STYLER_COMBO_FONT_NAME];
		style.fontName = f > 0 ? str(fonts[f]) : "";
		NSInteger sz = [d selectedIndex: IDC_STYLER_COMBO_FONT_SIZE];
		style.fontSize = sz > 0 ? [sizes[sz] intValue] : -1;
		style.nesting = SCE_USER_MASK_NESTING_NONE;
		for (const auto& [ctrl, mask] : kNesting)
			if ([d isChecked: ctrl])
				style.nesting |= mask;
		[weakSelf changed];
	};
	for (NSColorWell* w in @[fg, bg])
	{
		w.target = d;
		w.action = @selector(controlAction:);
	}
	d.onCommand = ^BOOL(NppRcDialog*, int cid) {
		if (cid == IDOK || cid == IDCANCEL)
			return NO;
		readBack();   // live preview, as upstream restyles while the dialog is open
		return YES;
	};
	if ([d runModal] != IDOK)
	{
		style = initial;
		[self changed];
		return;
	}
	readBack();
}

@end

@implementation NppMainWindow (UdlDialog)

+ (void)registerUdlDialogCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	t[IDM_LANG_USER_DLG] = ^(NppMainWindow* w) { [[NppUdlDialog shared] showForWindow: w]; };
}

// Documents using `name` are styled again after an edit in the dialog.
- (void)restyleUserLang:(NSString*)name
{
	for (int view = 0; view < 2; ++view)
		for (NppBuffer* b in [self buffersOfView: view])
			if ([b.userLangName isEqualToString: name] && b == self.currentBuffer)
				[self applyLanguage: b];
}

// A UDL was renamed (or removed when newName is nil): documents follow.
- (void)renameUserLang:(NSString*)oldName to:(NSString*)newName
{
	for (NppBuffer* b in [self allBuffers])
		if ([b.userLangName isEqualToString: oldName])
		{
			b.userLangName = newName;
			if (!newName)
				b.lang = LangManager::instance().languageByName("normal");
		}
	if (NppBuffer* b = self.currentBuffer)
		[self applyLanguage: b];
}

@end
