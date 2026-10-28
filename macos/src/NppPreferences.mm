#import "NppPreferences.h"
#import "NppRcDialog.h"
#import "NppTheme.h"
#import "NppStyleConfigurator.h"
#import "NppLocalization.h"

#include "LangManager.h"
#include "NppConfig.h"
#include "NppSettings.h"
#include "NppUpstream.h"
#include "preference_rc.h"
#include "EncodingMapper.h"

#include <functional>
#include <string>
#include <vector>

NSNotificationName const NppSettingsChangedNotification = @"NppSettingsChangedNotification";

namespace
{
	struct PrefPage { const char* title; const char* key; const char* idd; };
	const PrefPage kPages[] = {
#include "PrefPages.inc"
	};

	NSString* ns(const std::string& s) { return [NSString stringWithUTF8String: s.c_str()] ?: @""; }

	// One control <-> one setting.
	struct Binding
	{
		enum Kind { Check, Radio, IntEdit, Slider, Text, Popup } kind;
		int ctrl;
		int value = 0;                                   // Radio: value this button selects
		std::function<int()> get;
		std::function<void(int)> set;
		std::function<std::string()> gets;
		std::function<void(const std::string&)> sets;
	};
}

@implementation NppPreferences
{
	NppRcDialog* _dlg;
	NSMutableArray<NSView*>* _pages;
	std::vector<Binding> _bindings;
	BOOL _loading;
}

+ (instancetype)shared
{
	static NppPreferences* p = nil;
	if (!p)
		p = [[NppPreferences alloc] init];
	return p;
}

#pragma mark - Building

- (void)build
{
	_dlg = [[NppRcDialog alloc] initWithRC: @"preference.rc" dialog: @"IDD_PREFERENCE_BOX"];
	__weak NppPreferences* weakSelf = self;
	_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
		return [weakSelf command: cid notification: d.lastNotification];
	};

	NSView* root = _dlg.window.contentView;
	_pages = [NSMutableArray array];
	NSMutableArray* titles = [NSMutableArray array];
	for (const PrefPage& p : kPages)
	{
		NSString* idd = [NSString stringWithUTF8String: p.idd];
		NSString* rc = [idd isEqualToString: @"IDD_REGEXT_BOX"] ? @"regExtDlg.rc" : @"preference.rc";
		NSView* page = [NppRcDialog viewFromRC: rc dialog: idd owner: _dlg];
		// Pages are DIALOGEX 115, 10 inside the box.
		NSRect f = page.frame;
		f.origin = NSMakePoint(115 * 1.7, 10 * 1.85);
		page.frame = f;
		page.hidden = YES;
		[root addSubview: page];
		[_pages addObject: page];
		NSString* t = [NppLocalization titleForNode: @"Preference" child: [NSString stringWithUTF8String: p.key]];
		[titles addObject: t ?: [NSString stringWithUTF8String: p.title]];
	}
	_dlg.window.title = @"Preferences";
	[_dlg setItems: titles forList: IDC_LIST_DLGTITLE];
	[self fillLists];
	[self buildBindings];
	[self disableUnportable];
	[NppLocalization applyToDialog: _dlg node: @"Preference"];
	[_dlg setText: IDC_RADIO_DARKMODE_FOLLOWWINDOWS value: @"Follow macOS"];
	[_dlg select: 0 inList: IDC_LIST_DLGTITLE];
	[self showPageIndex: 0];
}

- (void)fillLists
{
	[_dlg setItems: @[@"0", @"1", @"2", @"3", @"Block", @"Block After"] forList: IDC_WIDTH_COMBO];
	[_dlg setItems: @[@"Enable for current file(s)", @"Enable for all opened files", @"Disable"] forList: IDC_COMBO_FILEUPDATECHOICE];

	NSMutableArray* langs = [NSMutableArray array];
	for (const auto& l : LangManager::instance().languages())
		[langs addObject: ns(l.displayName)];
	[_dlg setItems: langs forList: IDC_COMBO_DEFAULTLANG];

	// Localization: nativeLang/*.xml shipped with the app.
	NSString* dir = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: @"localization"];
	NSMutableArray* locs = [NSMutableArray array];
	for (NSString* f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath: dir error: nil] sortedArrayUsingSelector: @selector(localizedCaseInsensitiveCompare:)])
		if ([f hasSuffix: @".xml"])
			[locs addObject: f.stringByDeletingPathExtension];
	[_dlg setItems: locs forList: IDC_COMBO_LOCALIZATION];
	NSUInteger en = [locs indexOfObject: [NppLocalization currentLanguageFile]];
	if (en != NSNotFound)
		[_dlg select: en inList: IDC_COMBO_LOCALIZATION];

	NSMutableArray* tabLangs = [NSMutableArray arrayWithObject: @"[Default]"];
	[_dlg setItems: tabLangs forList: IDC_LIST_TABSETTNG];
	[_dlg select: 0 inList: IDC_LIST_TABSETTNG];

	// Codepages for "New Document > Encoding > other" (EncodingMapper order).
	NSMutableArray* cps = [NSMutableArray array];
	for (int i = 0;; ++i)
	{
		int cp = EncodingMapper::getInstance().getEncodingFromIndex(i);
		if (cp == 0 || i > 60)
			break;
		[cps addObject: cp > 0 ? [NSString stringWithFormat: @"CP%d", cp] : @"-"];
	}
	[_dlg setItems: cps forList: IDC_COMBO_OTHERCP];
}

// Controls for Windows-only features stay visible but disabled.
- (void)disableUnportable
{
	for (int cid : {IDC_CHECK_HIDEMENUBAR, IDC_CHECK_HIDERIGHTSHORTCUTSOFMENUBAR, IDC_COMBO_DIALOG_FONT_SIZE, IDC_COMBO_DIALOG_FONT_NAME,
	                IDC_COMBO_SYSTRAY_ACTION_CHOICE, IDC_COMBO_SC_TECHNOLOGY_CHOICE, IDC_COMBO_AUTOUPDATE, IDC_CHECK_SMOOTHFONT,
	                IDC_CHECK_DISABLEADVANCEDSCROLL, IDC_MONOINST_RADIO, IDC_MULTIINST_RADIO, IDC_SESSIONININST_RADIO,
	                IDC_CHECK_TAB_VERTICAL, IDC_CHECK_TAB_MULTILINE})
		[_dlg enable: cid value: NO];
}

- (void)buildBindings
{
	NppSettings& s = NppSettings::instance();
	auto& b = _bindings;
	auto chk = [&](int ctrl, bool& f, bool invert = false) {
		Binding x{Binding::Check, ctrl};
		bool* p = &f;
		x.get = [p, invert] { return (int)(*p != invert); };
		x.set = [p, invert](int v) { *p = (v != 0) != invert; };
		b.push_back(x);
	};
	auto radio = [&](int ctrl, int& f, int value) {
		Binding x{Binding::Radio, ctrl, value};
		int* p = &f;
		x.get = [p] { return *p; };
		x.set = [p](int v) { *p = v; };
		b.push_back(x);
	};
	auto radioStr = [&](int ctrl, std::string& f, const char* value, int idx) {
		Binding x{Binding::Radio, ctrl, idx};
		std::string* p = &f;
		std::string v = value;
		x.get = [p, v, idx] { return *p == v ? idx : -1; };
		x.set = [p, v](int) { *p = v; };
		b.push_back(x);
	};
	auto radioBool = [&](int ctrl, bool& f, bool value) {
		Binding x{Binding::Radio, ctrl, value ? 1 : 0};
		bool* p = &f;
		x.get = [p] { return *p ? 1 : 0; };
		x.set = [p](int v) { *p = v != 0; };
		b.push_back(x);
	};
	auto intEdit = [&](int ctrl, int& f) {
		Binding x{Binding::IntEdit, ctrl};
		int* p = &f;
		x.get = [p] { return *p; };
		x.set = [p](int v) { *p = v; };
		b.push_back(x);
	};
	auto slider = [&](int ctrl, int& f, int lo, int hi) {
		Binding x{Binding::Slider, ctrl, lo};
		int* p = &f;
		x.get = [p] { return *p; };
		x.set = [p](int v) { *p = v; };
		b.push_back(x);
		NSSlider* sl = (NSSlider*)[_dlg item: ctrl];
		sl.minValue = lo;
		sl.maxValue = hi;
	};
	auto text = [&](int ctrl, std::string& f) {
		Binding x{Binding::Text, ctrl};
		std::string* p = &f;
		x.gets = [p] { return *p; };
		x.sets = [p](const std::string& v) { *p = v; };
		b.push_back(x);
	};
	auto popup = [&](int ctrl, std::function<int()> get, std::function<void(int)> set) {
		Binding x{Binding::Popup, ctrl};
		x.get = get;
		x.set = set;
		b.push_back(x);
	};

	// General
	chk(IDC_CHECK_HIDESTATUSBAR, s._statusBarShow, true);
	chk(IDC_CHECK_HIDEMENUBAR, s._menuBarHide);
	chk(IDC_CHECK_HIDERIGHTSHORTCUTSOFMENUBAR, s._hideMenuRightShortcuts);

	// Toolbar
	chk(IDC_CHECK_HIDE, s._toolbarShow, true);
	radio(IDC_RADIO_SMALLICON, s._toolbarIconSet, 0);
	radio(IDC_RADIO_BIGICON, s._toolbarIconSet, 1);
	radio(IDC_RADIO_SMALLICON2, s._toolbarIconSet, 2);
	radio(IDC_RADIO_BIGICON2, s._toolbarIconSet, 3);
	radio(IDC_RADIO_STANDARD, s._toolbarIconSet, 4);

	// Tab Bar
	chk(IDC_CHECK_TAB_HIDE, s._tabBarHide);
	chk(IDC_CHECK_TAB_VERTICAL, s._tabVertical);
	chk(IDC_CHECK_TAB_MULTILINE, s._tabMultiLine);
	chk(IDC_CHECK_LOCK, s._tabDragAndDrop, true);
	chk(IDC_CHECK_DBCLICK2CLOSE, s._tabDoubleClickClose);
	chk(IDC_CHECK_TAB_LAST_EXIT, s._tabQuitOnEmpty);
	intEdit(IDC_EDIT_TABCOMPACTLABELLEN, s._tabCompactLabelLen);
	chk(IDC_CHECK_REDUCE, s._tabReduce);
	chk(IDC_CHECK_TAB_ALTICONS, s._tabAltIcons);
	chk(IDC_CHECK_DRAWINACTIVE, s._tabDrawInactive);
	chk(IDC_CHECK_ORANGE, s._tabDrawTopBar);
	chk(IDC_CHECK_ENABLETABCLOSE, s._tabCloseButton);
	chk(IDC_CHECK_ENABLETABPIN, s._tabPinButton);
	chk(IDC_CHECK_SHOWONLYPINNEDBUTTON, s._tabShowOnlyPinnedButton);
	chk(IDC_CHECK_INACTTABDRAWBUTTON, s._tabButtonsOnInactive);

	// Editing 1
	radio(IDC_RADIO_CLM_NONE, s._currentLineIndicator, 0);
	radio(IDC_RADIO_CLM_HILITE, s._currentLineIndicator, 1);
	radio(IDC_RADIO_CLM_FRAME, s._currentLineIndicator, 2);
	slider(IDC_CARETLINEFRAME_WIDTH_SLIDER, s._currentLineFrameWidth, 1, 6);
	popup(IDC_WIDTH_COMBO, [&s] { return s._caretWidth; }, [&s](int v) { s._caretWidth = v; });
	{
		// Slider runs slow (left) to fast (right): BLINKRATE_SLOWEST..BLINKRATE_FASTEST.
		Binding x{Binding::Slider, IDC_CARETBLINKRATE_SLIDER};
		x.get = [&s] { return 2550 - s._caretBlinkRate; };
		x.set = [&s](int v) { s._caretBlinkRate = 2550 - v; };
		b.push_back(x);
		NSSlider* sl = (NSSlider*)[_dlg item: IDC_CARETBLINKRATE_SLIDER];
		sl.minValue = 50;
		sl.maxValue = 2500;
	}
	radioStr(IDC_RADIO_LWDEF, s._lineWrapMethod, "default", 0);
	radioStr(IDC_RADIO_LWALIGN, s._lineWrapMethod, "aligned", 1);
	radioStr(IDC_RADIO_LWINDENT, s._lineWrapMethod, "indent", 2);
	chk(IDC_CHECK_SMOOTHFONT, s._smoothFont);
	chk(IDC_CHECK_VIRTUALSPACE, s._virtualSpace);
	chk(IDC_CHECK_FOLDINGTOGGLE, s._foldCmdToggable);
	chk(IDC_CHECK_RIGHTCLICKKEEPSSELECTION, s._rightClickKeepsSelection);
	chk(IDC_CHECK_LINECUTCOPYWITHOUTSELECTION, s._lineCopyCutWithoutSelection);
	chk(IDC_CHECK_SELECTEDTEXTSINGLECOLOR, s._selectedTextFgSingleColor);
	chk(IDC_CHECK_SCROLLBEYONDLASTLINE, s._scrollBeyondLastLine);
	chk(IDC_CHECK_DISABLEADVANCEDSCROLL, s._disableAdvancedScrolling);
	chk(IDC_CHECK_DISABLESELECTEDTEXTDRAGDROP, s._disableSelectedTextDragDrop);

	// Editing 2
	chk(IDC_CHECK_MULTISELECTION, s._multiSelection);
	chk(IDC_CHECK_COLUMN2MULTIEDITING, s._columnSel2MultiEdit);

	// Dark Mode: Light / Dark / Follow macOS
	{
		Binding light{Binding::Radio, IDC_RADIO_DARKMODE_LIGHTMODE, 0};
		Binding dark{Binding::Radio, IDC_RADIO_DARKMODE_DARKMODE, 1};
		Binding follow{Binding::Radio, IDC_RADIO_DARKMODE_FOLLOWWINDOWS, 2};
		auto get = [&s] { return s._darkModeFollowOS ? 2 : s._darkModeEnable ? 1 : 0; };
		auto set = [&s](int v) { s._darkModeFollowOS = v == 2; s._darkModeEnable = v == 1; };
		for (Binding* x : {&light, &dark, &follow})
		{
			x->get = get;
			x->set = set;
			b.push_back(*x);
		}
		[_dlg setText: IDC_RADIO_DARKMODE_FOLLOWWINDOWS value: @"Follow macOS"];
	}

	// Margins/Border/Edge
	radioStr(IDC_RADIO_SIMPLE, s._folderMarkStyle, "simple", 0);
	radioStr(IDC_RADIO_ARROW, s._folderMarkStyle, "arrow", 1);
	radioStr(IDC_RADIO_CIRCLE, s._folderMarkStyle, "circle", 2);
	radioStr(IDC_RADIO_BOX, s._folderMarkStyle, "box", 3);
	radioStr(IDC_RADIO_FOLDMARGENONE, s._folderMarkStyle, "none", 4);
	slider(IDC_BORDERWIDTH_SLIDER, s._borderWidth, 0, 30);
	chk(IDC_CHECK_NOEDGE, s._borderEdge, true);
	text(IDC_COLUMNPOS_EDIT, s._edgeMultiColumnPos);
	chk(IDC_CHECK_EDGEBGMODE, s._isEdgeBgMode);
	{
		Binding m{Binding::Check, IDC_CHECK_CHANGHISTORYMARGIN};
		m.get = [&s] { return (s._isChangeHistoryEnabled & 1) ? 1 : 0; };
		m.set = [&s](int v) { s._isChangeHistoryEnabled = v ? (s._isChangeHistoryEnabled | 1) : (s._isChangeHistoryEnabled & ~1); };
		b.push_back(m);
		Binding i{Binding::Check, IDC_CHECK_CHANGHISTORYINDICATOR};
		i.get = [&s] { return (s._isChangeHistoryEnabled & 2) ? 1 : 0; };
		i.set = [&s](int v) { s._isChangeHistoryEnabled = v ? (s._isChangeHistoryEnabled | 2) : (s._isChangeHistoryEnabled & ~2); };
		b.push_back(i);
	}
	chk(IDC_CHECK_LINENUMBERMARGE, s._lineNumberShow);
	radioBool(IDC_RADIO_DYNAMIC, s._lineNumberDynamicWidth, true);
	radioBool(IDC_RADIO_CONSTANT, s._lineNumberDynamicWidth, false);
	slider(IDC_PADDINGLEFT_SLIDER, s._paddingLeft, 0, 30);
	slider(IDC_PADDINGRIGHT_SLIDER, s._paddingRight, 0, 30);
	slider(IDC_DISTRACTIONFREE_SLIDER, s._distractionFreeDivPart, 3, 9);
	chk(IDC_CHECK_BOOKMARKMARGE, s._bookMarkMarginShow);

	// New Document
	radio(IDC_RADIO_F_WIN, s._newDocFormat, 0);
	radio(IDC_RADIO_F_UNIX, s._newDocFormat, 2);
	radio(IDC_RADIO_F_MAC, s._newDocFormat, 1);
	radio(IDC_RADIO_ANSI, s._newDocUnicodeMode, uni8Bit);
	radio(IDC_RADIO_UTF8_NO_BOM, s._newDocUnicodeMode, uniUTF8_NoBOM);
	radio(IDC_RADIO_UTF8, s._newDocUnicodeMode, uniUTF8);
	radio(IDC_RADIO_UTF16BIG, s._newDocUnicodeMode, uni16BE);
	radio(IDC_RADIO_UTF16SMALL, s._newDocUnicodeMode, uni16LE);
	chk(IDC_CHECK_OPENANSIASUTF8, s._openAnsiAsUtf8);
	popup(IDC_COMBO_DEFAULTLANG, [&s] { return s._newDocLang; }, [&s](int v) { s._newDocLang = v; });
	chk(IDC_CHECK_ADDNEWDOCONSTARTUP, s._addNewDocOnStartup);
	chk(IDC_CHECK_USECONTENTASTABNAME, s._useContentAsTabName);

	// Default Directory
	radio(IDC_OPENSAVEDIR_FOLLOWCURRENT_RADIO, s._openSaveDir, 0);
	radio(IDC_OPENSAVEDIR_REMEMBERLAST_RADIO, s._openSaveDir, 1);
	radio(IDC_OPENSAVEDIR_ALWAYSON_RADIO, s._openSaveDir, 2);
	text(IDC_OPENSAVEDIR_ALWAYSON_EDIT, s._defaultDirPath);
	chk(IDC_OPENSAVEDIR_CHECK_DROPFOLDEROPENFILES, s._isFolderDroppedOpenFiles);

	// Recent Files History
	chk(IDC_CHECK_DONTCHECKHISTORY, s._checkHistoryFiles, true);
	{
		Binding x{Binding::IntEdit, IDC_EDIT_MAXNBFILEVAL};
		x.get = [] { return NppConfig::instance().nbMaxRecentFiles; };
		x.set = [](int v) { NppConfig::instance().nbMaxRecentFiles = std::max(0, std::min(30, v)); };
		b.push_back(x);
	}

	// Language
	chk(IDC_CHECK_LANGMENUCOMPACT, s._langMenuCompact);
	chk(IDC_CHECK_BACKSLASHISESCAPECHARACTERFORSQL, s._backSlashIsEscapeCharacterForSql);

	// Indentation ([Default])
	intEdit(IDC_EDIT_TABSIZEVAL, s._tabSize);
	radioBool(IDC_RADIO_USINGTAB, s._tabReplaceBySpace, false);
	radioBool(IDC_RADIO_REPLACEBYSPACE, s._tabReplaceBySpace, true);
	chk(IDC_CHECK_BACKSPACEUNINDENT, s._backspaceUnindent);
	radio(IDC_RADIO_AUTOINDENT_NONE, s._maintainIndent, 0);
	radio(IDC_RADIO_AUTOINDENT_BASIC, s._maintainIndent, 1);
	radio(IDC_RADIO_AUTOINDENT_ADVANCED, s._maintainIndent, 2);

	// Highlighting
	chk(IDC_CHECK_MARKALLCASESENSITIVE, s._markAllCaseSensitive);
	chk(IDC_CHECK_MARKALLWHOLEWORDONLY, s._markAllWordOnly);
	chk(IDC_CHECK_ENABLTAGSMATCHHILITE, s._enableTagsMatchHilite);
	chk(IDC_CHECK_ENABLTAGATTRHILITE, s._enableTagAttrsHilite);
	chk(IDC_CHECK_HIGHLITENONEHTMLZONE, s._enableHiliteNonHTMLZone);
	chk(IDC_CHECK_ENABLSMARTHILITE, s._enableSmartHilite);
	chk(IDC_CHECK_SMARTHILITEANOTHERRVIEW, s._smartHiliteOnAnotherView);
	chk(IDC_CHECK_SMARTHILITECASESENSITIVE, s._smartHiliteCaseSensitive);
	chk(IDC_CHECK_SMARTHILITEWHOLEWORDONLY, s._smartHiliteWordOnly);
	chk(IDC_CHECK_SMARTHILITEUSEFINDSETTINGS, s._smartHiliteUseFindSettings);

	// Searching
	{
		Binding x{Binding::IntEdit, IDC_INSELECTION_THRESHOLD_EDIT};
		x.get = [&s] { return s._inSelectionAutocheckThreshold; };
		x.set = [&s](int v) { s._inSelectionAutocheckThreshold = v; };
		b.push_back(x);
	}
	chk(IDC_CHECK_FILL_DIR_FIELD_FROM_ACTIVE_DOC, s._fillDirFieldFromActiveDoc);
	chk(IDC_CHECK_FILL_FIND_FIELD_WITH_SELECTED, s._fillFindFieldWithSelected);
	intEdit(IDC_FILLFINDWHAT_THRESHOLD_EDIT, s._fillFindWhatThreshold);
	chk(IDC_CHECK_FILL_FIND_FIELD_SELECT_CARET, s._fillFindFieldSelectCaret);
	chk(IDC_CHECK_MONOSPACEDFONT_FINDDLG, s._monospacedFontFindDlg);
	chk(IDC_CHECK_FINDDLG_ALWAYS_VISIBLE, s._findDlgAlwaysVisible);
	chk(IDC_CHECK_SHOWONCEPERFOUNDLINE, s._finderShowOnlyOneEntryPerFoundLine);
	chk(IDC_CHECK_FIF_IGNOREOPENEDFILES, s._fifIgnoreUnsavedChanges);

	// Backup
	chk(IDC_CHECK_REMEMBERSESSION, s._rememberLastSession);
	chk(IDC_BACKUPDIR_RESTORESESSION_CHECK, s._isSnapshotMode);
	{
		Binding x{Binding::IntEdit, IDC_BACKUPDIR_RESTORESESSION_EDIT};
		x.get = [&s] { return s._snapshotBackupTiming / 1000; };
		x.set = [&s](int v) { s._snapshotBackupTiming = std::max(1, v) * 1000; };
		b.push_back(x);
	}
	chk(IDC_CHECK_KEEPABSENTFILESINSESSION, s._keepSessionAbsentFileEntries);
	radio(IDC_RADIO_BKNONE, s._backupAction, 0);
	radio(IDC_RADIO_BKSIMPLE, s._backupAction, 1);
	radio(IDC_RADIO_BKVERBOSE, s._backupAction, 2);
	chk(IDC_BACKUPDIR_CHECK, s._useCustomBackupDir);
	text(IDC_BACKUPDIR_EDIT, s._backupDir);

	// Auto-Completion
	{
		Binding x{Binding::Check, IDD_AUTOC_ENABLECHECK};
		x.get = [&s] { return s._autoCAction != 0 ? 1 : 0; };
		x.set = [&s](int v) { s._autoCAction = v ? 3 : 0; };
		b.push_back(x);
	}
	radio(IDD_AUTOC_FUNCRADIO, s._autoCAction, 1);
	radio(IDD_AUTOC_WORDRADIO, s._autoCAction, 2);
	radio(IDD_AUTOC_BOTHRADIO, s._autoCAction, 3);
	chk(IDD_AUTOC_BRIEF_CHECK, s._autoCBrief);
	chk(IDD_FUNC_CHECK, s._funcParams);
	slider(IDC_AUTOC_CHAR_SLIDER, s._autoCFromNbChar, 1, 9);
	chk(IDD_AUTOC_USETAB, s._autoCInsertWithTab);
	chk(IDD_AUTOC_USEENTER, s._autoCInsertWithEnter);
	chk(IDD_AUTOC_IGNORENUMBERS, s._autoCIgnoreNumbers);
	chk(IDD_AUTOCPARENTHESES_CHECK, s._insertParentheses);
	chk(IDD_AUTOCBRACKET_CHECK, s._insertBrackets);
	chk(IDD_AUTOCCURLYBRACKET_CHECK, s._insertCurlyBrackets);
	chk(IDD_AUTOC_QUOTESCHECK, s._insertQuotes);
	chk(IDD_AUTOCTAG_CHECK, s._insertHtmlXmlTag);

	// Multi-Instance & Date
	radio(IDC_MONOINST_RADIO, s._multiInstSetting, 0);
	radio(IDC_MULTIINST_RADIO, s._multiInstSetting, 1);
	radio(IDC_SESSIONININST_RADIO, s._multiInstSetting, 2);
	chk(IDD_DATETIMEFORMAT_REVERSEORDER_CHECK, s._dateTimeReverseDefaultOrder);
	text(IDC_DATETIMEFORMAT_EDIT, s._dateTimeFormat);

	// Delimiter
	radioBool(IDC_RADIO_WORDCHAR_DEFAULT, s._wordCharUseDefault, true);
	radioBool(IDC_RADIO_WORDCHAR_CUSTOM, s._wordCharUseDefault, false);
	text(IDC_WORDCHAR_CUSTOM_EDIT, s._wordCharsAdded);
	{
		Binding o{Binding::Text, IDC_EDIT_OPENDELIMITER};
		o.gets = [&s] { return std::string(1, (char)s._leftmostDelimiter); };
		o.sets = [&s](const std::string& v) { if (!v.empty()) s._leftmostDelimiter = (unsigned char)v[0]; };
		b.push_back(o);
		Binding c{Binding::Text, IDC_EDIT_CLOSEDELIMITER};
		c.gets = [&s] { return std::string(1, (char)s._rightmostDelimiter); };
		c.sets = [&s](const std::string& v) { if (!v.empty()) s._rightmostDelimiter = (unsigned char)v[0]; };
		b.push_back(c);
	}
	chk(IDD_SEVERALLINEMODEON_CHECK, s._delimiterSelectionOnEntireDocument);

	// Performance
	chk(IDC_CHECK_PERFORMANCE_ENABLE, s._largeFileRestrictionEnabled);
	intEdit(IDC_EDIT_PERFORMANCE_FILESIZE, s._largeFileSizeMB);
	chk(IDC_CHECK_PERFORMANCE_DEACTIVATEWORDWRAP, s._largeFileDeactivateWordWrap);
	chk(IDC_CHECK_PERFORMANCE_ALLOWAUTOCOMPLETION, s._largeFileAllowAutoCompletion);
	chk(IDC_CHECK_PERFORMANCE_ALLOWSMARTHILITE, s._largeFileAllowSmartHilite);
	chk(IDC_CHECK_PERFORMANCE_ALLOWBRACEMATCH, s._largeFileAllowBraceMatch);
	chk(IDC_CHECK_PERFORMANCE_ALLOWCLICKABLELINK, s._largeFileAllowClickableLink);
	chk(IDC_CHECK_PERFORMANCE_SUPPRESS2GBWARNING, s._largeFileSuppress2GBWarning);

	// Cloud & Link
	{
		Binding none{Binding::Radio, IDC_NOCLOUD_RADIO, 0};
		Binding with{Binding::Radio, IDC_WITHCLOUD_RADIO, 1};
		for (Binding* x : {&none, &with})
		{
			x->get = [&s] { return s._cloudPath.empty() ? 0 : 1; };
			x->set = [&s](int v) { if (!v) s._cloudPath.clear(); };
			b.push_back(*x);
		}
	}
	text(IDC_CLOUDPATH_EDIT, s._cloudPath);
	{
		Binding x{Binding::Check, IDC_CHECK_CLICKABLELINK_ENABLE};
		x.get = [&s] { return s._urlMode != 0 ? 1 : 0; };
		x.set = [&s](int v) { s._urlMode = v ? 2 : 0; };
		b.push_back(x);
	}
	text(IDC_URISCHEMES_EDIT, s._uriCustomizedSchemes);

	// Search Engine
	radio(IDC_SEARCHENGINE_DUCKDUCKGO_RADIO, s._searchEngineChoice, 3);
	radio(IDC_SEARCHENGINE_GOOGLE_RADIO, s._searchEngineChoice, 1);
	radio(IDC_SEARCHENGINE_YAHOO_RADIO, s._searchEngineChoice, 4);
	radio(IDC_SEARCHENGINE_STACKOVERFLOW_RADIO, s._searchEngineChoice, 5);
	radio(IDC_SEARCHENGINE_CUSTOM_RADIO, s._searchEngineChoice, 0);
	text(IDC_SEARCHENGINE_EDIT, s._searchEngineCustom);

	// MISC
	popup(IDC_COMBO_FILEUPDATECHOICE,
	      [&s] { int d = s._fileAutoDetection; return (d & cdEnabled4AllFiles) ? 1 : (d & cdEnabled4CurrentFile) ? 0 : 2; },
	      [&s](int v) {
		      int keep = s._fileAutoDetection & (cdAutoUpdate | cdGo2end);
		      s._fileAutoDetection = (v == 0 ? cdEnabled4CurrentFile : v == 1 ? cdEnabled4AllFiles : cdDisabled) | (v == 2 ? 0 : keep);
	      });
	{
		Binding x{Binding::Check, IDC_CHECK_UPDATESILENTLY};
		x.get = [&s] { return (s._fileAutoDetection & cdAutoUpdate) ? 1 : 0; };
		x.set = [&s](int v) { s._fileAutoDetection = v ? (s._fileAutoDetection | cdAutoUpdate) : (s._fileAutoDetection & ~cdAutoUpdate); };
		b.push_back(x);
		Binding y{Binding::Check, IDC_CHECK_UPDATEGOTOEOF};
		y.get = [&s] { return (s._fileAutoDetection & cdGo2end) ? 1 : 0; };
		y.set = [&s](int v) { s._fileAutoDetection = v ? (s._fileAutoDetection | cdGo2end) : (s._fileAutoDetection & ~cdGo2end); };
		b.push_back(y);
	}
	chk(IDC_CHECK_ENABLEDOCPEEKER, s._docPeekOnTab);
	chk(IDC_CHECK_ENABLEDOCPEEKONMAP, s._docPeekOnMap);
	chk(IDC_CHECK_MUTE_SOUNDS, s._muteSounds);
	chk(IDC_CHECK_DETECTENCODING, s._detectEncoding);
	chk(IDC_CHECK_SHORTTITLE, s._shortTitlebar);
	chk(IDC_CHECK_SAVEALLCONFIRM, s._saveAllConfirm);
	text(IDC_EDIT_SESSIONFILEEXT, s._sessionExt);
	text(IDC_EDIT_WORKSPACEFILEEXT, s._workspaceExt);
}

#pragma mark - Showing

- (void)show
{
	if (!_dlg)
		[self build];
	[self loadValues];
	[_dlg showModeless];
}

- (void)showPage:(NSString*)internalName
{
	[self show];
	for (size_t i = 0; i < std::size(kPages); ++i)
		if ([internalName isEqualToString: [NSString stringWithUTF8String: kPages[i].key]])
		{
			[_dlg select: i inList: IDC_LIST_DLGTITLE];
			[self showPageIndex: i];
		}
}

- (void)showPageIndex:(NSInteger)idx
{
	for (NSInteger i = 0; i < (NSInteger)_pages.count; ++i)
		_pages[i].hidden = i != idx;
}

- (void)loadValues
{
	_loading = YES;
	for (const Binding& x : _bindings)
	{
		switch (x.kind)
		{
			case Binding::Check: [_dlg setChecked: x.ctrl value: x.get() != 0]; break;
			case Binding::Radio: if (x.get() == x.value) [_dlg setChecked: x.ctrl value: YES]; break;
			case Binding::IntEdit: [_dlg setText: x.ctrl value: [NSString stringWithFormat: @"%d", x.get()]]; break;
			case Binding::Slider: ((NSSlider*)[_dlg item: x.ctrl]).integerValue = x.get(); break;
			case Binding::Text: [_dlg setText: x.ctrl value: ns(x.gets())]; break;
			case Binding::Popup: [_dlg select: x.get() inList: x.ctrl]; break;
		}
	}
	const NppSettings& s = NppSettings::instance();
	[_dlg enable: IDC_CARETLINEFRAME_WIDTH_SLIDER value: s._currentLineIndicator == 2];
	_loading = NO;
}

#pragma mark - Commands

- (BOOL)command:(int)cid notification:(int)code
{
	if (_loading)
		return YES;
	if (cid == IDC_COMBO_LOCALIZATION)
	{
		NSString* lang = [_dlg text: cid];
		if (lang.length && ![lang isEqualToString: [NppLocalization currentLanguageFile]])
		{
			[NppLocalization selectLanguage: lang];
			// Rebuild the dialog so it comes back translated.
			[_dlg endWith: IDCANCEL];
			_dlg = nil;
			dispatch_async(dispatch_get_main_queue(), ^{ [self show]; });
		}
		return YES;
	}
	if (cid == IDC_LIST_DLGTITLE)
	{
		[self showPageIndex: [_dlg selectedIndex: cid]];
		return YES;
	}
	if (cid == IDC_BUTTON_CLOSE || cid == IDCANCEL)
	{
		NppConfig::instance().save();
		[_dlg endWith: IDCANCEL];
		return YES;
	}
	if (cid == IDC_BUTTON_LAUNCHSTYLECONF_CRLF || cid == IDC_BUTTON_NPC_LAUNCHSTYLECONF)
	{
		[[NppStyleConfigurator shared] goToSection: @"Global Styles"];
		return YES;
	}

	BOOL handled = NO;
	for (const Binding& x : _bindings)
	{
		if (x.ctrl != cid)
			continue;
		switch (x.kind)
		{
			case Binding::Check: x.set([_dlg isChecked: cid]); break;
			case Binding::Radio: if ([_dlg isChecked: cid]) x.set(x.value); break;
			case Binding::IntEdit: x.set([_dlg text: cid].intValue); break;
			case Binding::Slider: x.set((int)((NSSlider*)[_dlg item: cid]).integerValue); break;
			case Binding::Text: x.sets([_dlg text: cid].UTF8String); break;
			case Binding::Popup: x.set((int)[_dlg selectedIndex: cid]); break;
		}
		handled = YES;
	}
	if (!handled)
		return NO;

	if (cid == IDC_RADIO_DARKMODE_LIGHTMODE || cid == IDC_RADIO_DARKMODE_DARKMODE || cid == IDC_RADIO_DARKMODE_FOLLOWWINDOWS)
		[NppTheme applyMode];
	[_dlg enable: IDC_CARETLINEFRAME_WIDTH_SLIDER value: NppSettings::instance()._currentLineIndicator == 2];
	[NSNotificationCenter.defaultCenter postNotificationName: NppSettingsChangedNotification object: nil];
	return YES;
}

@end
