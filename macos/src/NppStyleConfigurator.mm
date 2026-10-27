#import "NppStyleConfigurator.h"
#import "NppRcDialog.h"
#import "NppTheme.h"

#include "LangManager.h"
#include "NppSettings.h"
#include "NppUpstream.h"
#include "WordStyleDlgRes.h"

#include <string>
#include <vector>

namespace
{
	NSString* ns(const std::string& s) { return [NSString stringWithUTF8String: s.c_str()] ?: @""; }

	NSColor* toColor(int rgb)
	{
		return [NSColor colorWithSRGBRed: ((rgb >> 16) & 0xFF) / 255.0 green: ((rgb >> 8) & 0xFF) / 255.0 blue: (rgb & 0xFF) / 255.0 alpha: 1];
	}

	int fromColor(NSColor* c)
	{
		NSColor* s = [c colorUsingColorSpace: NSColorSpace.sRGBColorSpace];
		int r = (int)lround(s.redComponent * 255), g = (int)lround(s.greenComponent * 255), b = (int)lround(s.blueComponent * 255);
		return (r << 16) | (g << 8) | b;
	}

	const wchar_t* const kFontSizes[] = {L"", L"5", L"6", L"7", L"8", L"9", L"10", L"11", L"12", L"14", L"16", L"18", L"20", L"22", L"24", L"26", L"28"};
}

@implementation NppStyleConfigurator
{
	NppRcDialog* _dlg;
	NSColorWell* _fg;
	NSColorWell* _bg;
	NSInteger _lexerIndex;        // 0 = Global Styles, else lexers()[index - 1]
	NSInteger _styleIndex;
	std::vector<std::pair<std::string, std::string>> _themes;
	BOOL _updating;
}

+ (instancetype)shared
{
	static NppStyleConfigurator* s = nil;
	if (!s)
		s = [[NppStyleConfigurator alloc] init];
	return s;
}

- (void)build
{
	_dlg = [[NppRcDialog alloc] initWithRC: @"WordStyleDlg.rc" dialog: @"IDD_STYLER_DLG"];
	__weak NppStyleConfigurator* weakSelf = self;
	_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
		return [weakSelf command: cid notification: d.lastNotification];
	};

	// Colour pickers sit right of their labels, like WordStyleDlg::move2CtrlRight.
	NSView* root = _dlg.window.contentView;
	auto well = [&](int labelId) {
		NSRect lr = [_dlg item: labelId].frame;
		NSColorWell* w = [[NSColorWell alloc] initWithFrame: NSMakeRect(NSMaxX(lr) + 8, lr.origin.y - 4, 44, 22)];
		w.target = self;
		w.action = @selector(colourChanged:);
		[root addSubview: w];
		return w;
	};
	_fg = well(IDC_FG_STATIC);
	_bg = well(IDC_BG_STATIC);

	NSMutableArray* fonts = [NSMutableArray arrayWithObject: @""];
	[fonts addObjectsFromArray: [NSFontManager.sharedFontManager.availableFontFamilies sortedArrayUsingSelector: @selector(localizedCaseInsensitiveCompare:)]];
	[_dlg setItems: fonts forList: IDC_FONT_COMBO];
	NSMutableArray* sizes = [NSMutableArray array];
	for (const wchar_t* w : kFontSizes)
		[sizes addObject: [[NSString alloc] initWithBytes: w length: wcslen(w) * sizeof(wchar_t) encoding: NSUTF32LittleEndianStringEncoding]];
	[_dlg setItems: sizes forList: IDC_FONTSIZE_COMBO];
}

- (void)show
{
	if (!_dlg)
		[self build];
	[self loadLists];
	[_dlg showModeless];
}

- (void)loadLists
{
	_updating = YES;
	LangManager& lm = LangManager::instance();

	_themes = lm.themes();
	NSMutableArray* names = [NSMutableArray array];
	NSInteger current = 0;
	for (size_t i = 0; i < _themes.size(); ++i)
	{
		[names addObject: ns(_themes[i].first)];
		if (_themes[i].second == lm.stylesPath())
			current = i;
	}
	[_dlg setItems: names forList: IDC_SWITCH2THEME_COMBO];
	[_dlg select: current inList: IDC_SWITCH2THEME_COMBO];

	NSMutableArray* langs = [NSMutableArray arrayWithObject: @"Global Styles"];
	for (const auto& l : lm.lexers())
		[langs addObject: ns(l.desc)];
	[_dlg setItems: langs forList: IDC_LANGUAGES_COMBO];
	if (_lexerIndex >= (NSInteger)langs.count)
		_lexerIndex = 0;
	[_dlg select: _lexerIndex inList: IDC_LANGUAGES_COMBO];
	_updating = NO;
	[self setStyleListFromLexer];
}

- (void)goToSection:(NSString*)lexerDesc
{
	[self show];
	if ([lexerDesc isEqualToString: @"Global Styles"])
		_lexerIndex = 0;
	else
	{
		auto& lexers = LangManager::instance().lexers();
		for (size_t i = 0; i < lexers.size(); ++i)
			if ([ns(lexers[i].desc) isEqualToString: lexerDesc])
				_lexerIndex = i + 1;
	}
	[self loadLists];
}

- (std::vector<NppStyle>&)currentStyles
{
	LangManager& lm = LangManager::instance();
	return _lexerIndex == 0 ? lm.globalStyles() : lm.lexers()[_lexerIndex - 1].styles;
}

- (NppStyle*)currentStyle
{
	auto& styles = [self currentStyles];
	return (_styleIndex >= 0 && _styleIndex < (NSInteger)styles.size()) ? &styles[_styleIndex] : nullptr;
}

// Port of WordStyleDlg::setStyleListFromLexer.
- (void)setStyleListFromLexer
{
	_updating = YES;
	NSMutableArray* items = [NSMutableArray array];
	for (const auto& s : [self currentStyles])
		[items addObject: ns(s.name)];
	[_dlg setItems: items forList: IDC_STYLES_LIST];
	_styleIndex = 0;
	[_dlg select: 0 inList: IDC_STYLES_LIST];

	BOOL isGlobal = _lexerIndex == 0;
	for (int cid : {IDC_DEF_EXT_STATIC, IDC_DEF_EXT_EDIT, IDC_USER_EXT_STATIC, IDC_USER_EXT_EDIT, IDC_PLUSSYMBOL2_STATIC})
		[_dlg show: cid value: !isGlobal];
	if (!isGlobal)
	{
		const LexerStyler& ls = LangManager::instance().lexers()[_lexerIndex - 1];
		const NppLang* lang = LangManager::instance().languageByName(ls.name);
		NSMutableArray* exts = [NSMutableArray array];
		if (lang)
			for (const auto& e : lang->extensions)
				[exts addObject: ns(e)];
		[_dlg setText: IDC_DEF_EXT_EDIT value: [exts componentsJoinedByString: @" "]];
		[_dlg setText: IDC_USER_EXT_EDIT value: ns(ls.userExt)];
	}
	_updating = NO;
	[self setVisualFromStyleList];
}

// Port of WordStyleDlg::setVisualFromStyleList.
- (void)setVisualFromStyleList
{
	NppStyle* st = [self currentStyle];
	if (!st)
		return;
	_updating = YES;

	BOOL isGlobalOverride = st->name == "Global override";
	for (int cid : {IDC_GLOBAL_FG_CHECK, IDC_GLOBAL_BG_CHECK, IDC_GLOBAL_FONT_CHECK, IDC_GLOBAL_FONTSIZE_CHECK,
	                IDC_GLOBAL_BOLD_CHECK, IDC_GLOBAL_ITALIC_CHECK, IDC_GLOBAL_UNDERLINE_CHECK, IDC_GLOBAL_WHATISGLOBALOVERRIDE_LINK})
		[_dlg show: cid value: isGlobalOverride];
	[_dlg show: IDC_GLOBAL_GOTOSETTINGS_LINK value: NO];
	if (isGlobalOverride)
	{
		const GlobalOverride& go = LangManager::instance().globalOverride;
		[_dlg setChecked: IDC_GLOBAL_FG_CHECK value: go.enableFg];
		[_dlg setChecked: IDC_GLOBAL_BG_CHECK value: go.enableBg];
		[_dlg setChecked: IDC_GLOBAL_FONT_CHECK value: go.enableFont];
		[_dlg setChecked: IDC_GLOBAL_FONTSIZE_CHECK value: go.enableFontSize];
		[_dlg setChecked: IDC_GLOBAL_BOLD_CHECK value: go.enableBold];
		[_dlg setChecked: IDC_GLOBAL_ITALIC_CHECK value: go.enableItalic];
		[_dlg setChecked: IDC_GLOBAL_UNDERLINE_CHECK value: go.enableUnderLine];
	}

	NSString* lang = _lexerIndex == 0 ? @"Global Styles" : ns(LangManager::instance().lexers()[_lexerIndex - 1].desc);
	[_dlg setText: IDC_STYLEDESCRIPTION_STATIC value: [NSString stringWithFormat: @"%@ : %s", lang, st->name.c_str()]];

	_fg.enabled = st->fgColor >= 0 && st->name != "Selected text colour";
	if (st->fgColor >= 0)
		_fg.color = toColor(st->fgColor);
	_bg.enabled = st->bgColor >= 0;
	if (st->bgColor >= 0)
		_bg.color = toColor(st->bgColor);

	NSPopUpButton* font = (NSPopUpButton*)[_dlg item: IDC_FONT_COMBO];
	NSInteger fi = st->fontName.empty() ? 0 : [font indexOfItemWithTitle: ns(st->fontName)];
	if (fi < 0)
	{
		// Theme font not installed on this Mac (e.g. Consolas): still show its name.
		[font.menu addItemWithTitle: ns(st->fontName) action: nil keyEquivalent: @""];
		fi = font.numberOfItems - 1;
	}
	[font selectItemAtIndex: fi];
	NSPopUpButton* size = (NSPopUpButton*)[_dlg item: IDC_FONTSIZE_COMBO];
	NSInteger si = st->fontSize > 0 ? [size indexOfItemWithTitle: [NSString stringWithFormat: @"%d", st->fontSize]] : 0;
	[size selectItemAtIndex: si < 0 ? 0 : si];
	BOOL fontOK = st->fontEnabled;
	for (int cid : {IDC_FONT_COMBO, IDC_FONTSIZE_COMBO, IDC_BOLD_CHECK, IDC_ITALIC_CHECK, IDC_UNDERLINE_CHECK})
		[_dlg enable: cid value: fontOK];
	int fs = st->fontStyle < 0 ? 0 : st->fontStyle;
	[_dlg setChecked: IDC_BOLD_CHECK value: (fs & FONTSTYLE_BOLD) != 0];
	[_dlg setChecked: IDC_ITALIC_CHECK value: (fs & FONTSTYLE_ITALIC) != 0];
	[_dlg setChecked: IDC_UNDERLINE_CHECK value: (fs & FONTSTYLE_UNDERLINE) != 0];

	BOOL showKw = st->keywordClass >= 0 && _lexerIndex > 0;
	for (int cid : {IDC_DEF_KEYWORDS_STATIC, IDC_DEF_KEYWORDS_EDIT, IDC_USER_KEYWORDS_STATIC, IDC_USER_KEYWORDS_EDIT, IDC_PLUSSYMBOL_STATIC})
		[_dlg show: cid value: showKw];
	if (showKw)
	{
		const NppLang* l = LangManager::instance().languageByName(LangManager::instance().lexers()[_lexerIndex - 1].name);
		[_dlg setText: IDC_DEF_KEYWORDS_EDIT value: l && st->keywordClass < NB_KEYWORD_LIST ? ns(l->keywords[st->keywordClass]) : @""];
		[_dlg setText: IDC_USER_KEYWORDS_EDIT value: ns(st->keywords)];
	}
	_updating = NO;
}

- (void)apply
{
	[NppTheme notifyStylesChanged];
}

- (void)colourChanged:(NSColorWell*)sender
{
	NppStyle* st = [self currentStyle];
	if (!st || _updating)
		return;
	if (sender == _fg)
		st->fgColor = fromColor(sender.color);
	else
		st->bgColor = fromColor(sender.color);
	[self apply];
}

- (void)setFontStyleBit:(int)bit on:(BOOL)on
{
	NppStyle* st = [self currentStyle];
	if (st->fontStyle < 0)
		st->fontStyle = 0;
	st->fontStyle = on ? (st->fontStyle | bit) : (st->fontStyle & ~bit);
}

- (BOOL)command:(int)cid notification:(int)code
{
	if (_updating)
		return YES;
	NppStyle* st = [self currentStyle];
	LangManager& lm = LangManager::instance();
	GlobalOverride& go = lm.globalOverride;
	switch (cid)
	{
		case IDC_SWITCH2THEME_COMBO:
		{
			NSInteger i = [_dlg selectedIndex: cid];
			if (i < 0 || i >= (NSInteger)_themes.size())
				return YES;
			[NppTheme switchToThemeAtPath: ns(_themes[i].second)];
			// Remember the choice for the current mode, like upstream's lightThemeName/darkThemeName.
			NppSettings& s = NppSettings::instance();
			std::string file = i == 0 ? "" : _themes[i].second.substr(_themes[i].second.find_last_of('/') + 1);
			([NppTheme isDark] ? s._darkThemeName : s._lightThemeName) = i == 0 ? "stylers.xml" : file;
			[self loadLists];
			return YES;
		}
		case IDC_LANGUAGES_COMBO:
			_lexerIndex = [_dlg selectedIndex: cid];
			[self setStyleListFromLexer];
			return YES;
		case IDC_STYLES_LIST:
			_styleIndex = [_dlg selectedIndex: cid];
			[self setVisualFromStyleList];
			return YES;
		case IDC_FONT_COMBO:
			if (st)
			{
				NSString* f = [_dlg text: cid];
				st->fontName = f.UTF8String;
				[self apply];
			}
			return YES;
		case IDC_FONTSIZE_COMBO:
			if (st)
			{
				NSString* f = [_dlg text: cid];
				st->fontSize = f.length ? f.intValue : 0;
				[self apply];
			}
			return YES;
		case IDC_BOLD_CHECK:
		case IDC_ITALIC_CHECK:
		case IDC_UNDERLINE_CHECK:
			if (st)
			{
				int bit = cid == IDC_BOLD_CHECK ? FONTSTYLE_BOLD : cid == IDC_ITALIC_CHECK ? FONTSTYLE_ITALIC : FONTSTYLE_UNDERLINE;
				[self setFontStyleBit: bit on: [_dlg isChecked: cid]];
				[self apply];
			}
			return YES;
		case IDC_USER_KEYWORDS_EDIT:
			if (st && code == 0x0300)
			{
				st->keywords = [_dlg text: cid].UTF8String;
				[self apply];
			}
			return YES;
		case IDC_USER_EXT_EDIT:
			if (_lexerIndex > 0 && code == 0x0300)
				lm.lexers()[_lexerIndex - 1].userExt = [_dlg text: cid].UTF8String;
			return YES;
		case IDC_GLOBAL_FG_CHECK: go.enableFg = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_BG_CHECK: go.enableBg = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_FONT_CHECK: go.enableFont = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_FONTSIZE_CHECK: go.enableFontSize = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_BOLD_CHECK: go.enableBold = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_ITALIC_CHECK: go.enableItalic = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_GLOBAL_UNDERLINE_CHECK: go.enableUnderLine = [_dlg isChecked: cid]; [self apply]; return YES;
		case IDC_SAVECLOSE_BUTTON:
			lm.saveStyles();
			[_dlg endWith: IDOK];
			return YES;
		case IDCANCEL:
			// Drop unsaved edits: reload the theme from disk.
			lm.loadStyles(lm.stylesPath());
			[self apply];
			[_dlg endWith: IDCANCEL];
			return YES;
	}
	return NO;
}

@end
