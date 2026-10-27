#import "NppToolbar.h"
#import "NppMenuBuilder.h"
#import <objc/runtime.h>

#include "NppUpstream.h"

#include <cmath>
#include <cstring>
#include <map>
#include <string>

namespace
{
	// "IDI_NEW_ICON ICON "icons/light/toolbar/regular/new_off.ico"" -> path.
	const std::map<std::string, std::string>& resourceFiles()
	{
		static std::map<std::string, std::string> files;
		if (!files.empty())
			return files;
		NSString* rc = [NSString stringWithContentsOfFile: [NSBundle.mainBundle pathForResource: @"Notepad_plus" ofType: @"rc"]
		                                         encoding: NSUTF8StringEncoding error: nil];
		for (NSString* line in [rc componentsSeparatedByCharactersInSet: NSCharacterSet.newlineCharacterSet])
		{
			NSArray* parts = [[line stringByTrimmingCharactersInSet: NSCharacterSet.whitespaceCharacterSet]
			                  componentsSeparatedByCharactersInSet: NSCharacterSet.whitespaceCharacterSet];
			NSMutableArray* tokens = [NSMutableArray array];
			for (NSString* p in parts)
				if (p.length)
					[tokens addObject: p];
			if (tokens.count < 3 || !([tokens[1] isEqualToString: @"ICON"] || [tokens[1] isEqualToString: @"BITMAP"]))
				continue;
			NSString* file = [tokens[2] stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"\""]];
			files[[tokens[0] UTF8String]] = [file stringByReplacingOccurrencesOfString: @"\\\\" withString: @"/"].UTF8String;
		}
		return files;
	}

	NSImage* loadIcon(const char* resName, CGFloat size)
	{
		if (!resName)
			return nil;
		auto it = resourceFiles().find(resName);
		if (it == resourceFiles().end())
			return nil;
		NSString* path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: [NSString stringWithUTF8String: it->second.c_str()]];
		NSImage* img = [[NSImage alloc] initWithContentsOfFile: path];
		if (!img)
			return nil;
		// .ico files hold several sizes; pick the best one for the target size.
		NSImageRep* best = nil;
		for (NSImageRep* r in img.representations)
			if (!best || fabs(r.pixelsWide - size * 2) < fabs(best.pixelsWide - size * 2))
				best = r;
		NSImage* out = [[NSImage alloc] initWithSize: NSMakeSize(size, size)];
		if (best)
			[out addRepresentation: best];
		out.size = NSMakeSize(size, size);
		return out;
	}

	bool isToggleCommand(int cmd)
	{
		switch (cmd)
		{
			case IDM_VIEW_WRAP:
			case IDM_VIEW_ALL_CHARACTERS:
			case IDM_VIEW_INDENT_GUIDE:
			case IDM_VIEW_SYNSCROLLV:
			case IDM_VIEW_SYNSCROLLH:
			case IDM_VIEW_DOC_MAP:
			case IDM_VIEW_DOCLIST:
			case IDM_VIEW_FUNC_LIST:
			case IDM_VIEW_FILEBROWSER:
			case IDM_VIEW_MONITORING:
			case IDM_LANG_USER_DLG:
				return true;
			default:
				return false;
		}
	}
}

@implementation NppToolbar
{
	NSStackView* _stack;
	NSMutableArray<NSButton*>* _buttons;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super initWithFrame: frame]))
	{
		_buttons = [NSMutableArray array];
		_stack = [[NSStackView alloc] init];
		_stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
		_stack.spacing = 1;
		_stack.edgeInsets = NSEdgeInsetsMake(2, 4, 2, 4);
		_stack.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview: _stack];
		[NSLayoutConstraint activateConstraints: @[
			[_stack.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
			[_stack.centerYAnchor constraintEqualToAnchor: self.centerYAnchor],
		]];
		[self buildButtons];
	}
	return self;
}

- (CGFloat)iconSize
{
	return (_iconSet == NppToolbarLarge || _iconSet == NppToolbarLarge2) ? 24 : 16;
}

- (CGFloat)preferredHeight
{
	return [self iconSize] + 12;
}

- (void)buildButtons
{
	size_t n = 0;
	const ToolbarIconDef* defs = NppUpstream::toolbarIcons(n);
	for (size_t i = 0; i < n; ++i)
	{
		if (defs[i].cmd == 0)
		{
			NSBox* sep = [[NSBox alloc] init];
			sep.boxType = NSBoxSeparator;
			[sep.widthAnchor constraintEqualToConstant: 1].active = YES;
			[sep.heightAnchor constraintEqualToConstant: 18].active = YES;
			[_stack addArrangedSubview: sep];
			[_stack setCustomSpacing: 5 afterView: _stack.arrangedSubviews.count > 1 ? _stack.arrangedSubviews[_stack.arrangedSubviews.count - 2] : sep];
			[_stack setCustomSpacing: 5 afterView: sep];
			continue;
		}
		NSButton* b = [[NSButton alloc] init];
		b.bezelStyle = NSBezelStyleTexturedRounded;
		b.bordered = NO;
		[b setButtonType: isToggleCommand(defs[i].cmd) ? NSButtonTypePushOnPushOff : NSButtonTypeMomentaryChange];
		b.tag = defs[i].cmd;
		b.target = self;
		b.action = @selector(buttonPressed:);
		b.imagePosition = NSImageOnly;
		b.translatesAutoresizingMaskIntoConstraints = NO;
		[_buttons addObject: b];
		[_stack addArrangedSubview: b];
	}
	[self reloadIcons];
}

- (void)setIconSet:(NppToolbarIconSet)iconSet
{
	_iconSet = iconSet;
	[self reloadIcons];
}

- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self reloadIcons];
}

- (const ToolbarIconDef*)defFor:(int)cmd
{
	size_t n = 0;
	const ToolbarIconDef* defs = NppUpstream::toolbarIcons(n);
	for (size_t i = 0; i < n; ++i)
		if (defs[i].cmd == cmd)
			return &defs[i];
	return nullptr;
}

- (void)reloadIcons
{
	BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames: @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
	BOOL filled = _iconSet == NppToolbarSmall2 || _iconSet == NppToolbarLarge2;
	CGFloat size = [self iconSize];
	for (NSButton* b in _buttons)
	{
		const ToolbarIconDef* d = [self defFor: (int)b.tag];
		if (!d)
			continue;
		const char* normal;
		const char* gray;
		if (_iconSet == NppToolbarStandard)
		{
			normal = d->stdIcon;
			gray = nullptr;
		}
		else if (dark)
		{
			normal = filled ? d->iconDM2 : d->iconDM;
			gray = filled ? d->grayIconDM2 : d->grayIconDM;
		}
		else
		{
			normal = filled ? d->icon2 : d->icon;
			gray = filled ? d->grayIcon2 : d->grayIcon;
		}
		NSImage* img = loadIcon(normal, size);
		NSImage* dis = gray && std::strcmp(gray, normal) != 0 ? loadIcon(gray, size) : nil;
		b.image = img;
		objc_setAssociatedObject(b, "normal", img, OBJC_ASSOCIATION_RETAIN);
		objc_setAssociatedObject(b, "disabled", dis, OBJC_ASSOCIATION_RETAIN);
		[NSLayoutConstraint deactivateConstraints: b.constraints];
		[b.widthAnchor constraintEqualToConstant: size + 8].active = YES;
		[b.heightAnchor constraintEqualToConstant: size + 6].active = YES;
	}
	[self updateTooltips];
	[self updateStates];
}

// Tooltips are the menu item texts, as in Notepad++.
- (void)updateTooltips
{
	for (NSButton* b in _buttons)
	{
		NSMenuItem* mi = [self menuItemWithTag: b.tag in: NSApp.mainMenu];
		b.toolTip = mi.title;
	}
}

- (NSMenuItem*)menuItemWithTag:(NSInteger)tag in:(NSMenu*)menu
{
	for (NSMenuItem* mi in menu.itemArray)
	{
		if (mi.tag == tag && !mi.submenu)
			return mi;
		if (mi.submenu)
			if (NSMenuItem* found = [self menuItemWithTag: tag in: mi.submenu])
				return found;
	}
	return nil;
}

- (void)updateStates
{
	for (NSButton* b in _buttons)
	{
		int cmd = (int)b.tag;
		BOOL enabled = _isEnabled ? _isEnabled(cmd) : YES;
		b.enabled = enabled;
		NSImage* dis = objc_getAssociatedObject(b, "disabled");
		NSImage* normal = objc_getAssociatedObject(b, "normal");
		b.image = (!enabled && dis) ? dis : normal;
		if (isToggleCommand(cmd) && _isChecked)
		{
			BOOL on = _isChecked(cmd);
			b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
			// Checked toggles get a pressed look, like the Win32 toolbar.
			b.wantsLayer = YES;
			b.layer.cornerRadius = 3;
			b.layer.backgroundColor = on ? [NSColor.controlAccentColor colorWithAlphaComponent: 0.25].CGColor : nil;
		}
	}
}

- (void)buttonPressed:(NSButton*)sender
{
	if (_onCommand)
		_onCommand((int)sender.tag);
	[self updateStates];
}

- (void)drawRect:(NSRect)dirtyRect
{
	[NSColor.windowBackgroundColor setFill];
	NSRectFill(self.bounds);
	[NSColor.separatorColor setFill];
	NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
}

@end
