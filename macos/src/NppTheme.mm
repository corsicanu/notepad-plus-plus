#import "NppTheme.h"

#include "LangManager.h"
#include "NppSettings.h"

NSNotificationName const NppStylesChangedNotification = @"NppStylesChangedNotification";

@implementation NppTheme

+ (BOOL)isDark
{
	const NppSettings& s = NppSettings::instance();
	if (s._darkModeFollowOS)
	{
		NSAppearanceName n = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames: @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
		return [n isEqualToString: NSAppearanceNameDarkAqua];
	}
	return s._darkModeEnable;
}

+ (void)applyMode
{
	const NppSettings& s = NppSettings::instance();
	NSApp.appearance = s._darkModeFollowOS ? nil
	                 : [NSAppearance appearanceNamed: s._darkModeEnable ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	BOOL dark = [self isDark];
	std::string name = dark ? s._darkThemeName : s._lightThemeName;
	std::string path = LangManager::instance().themePathForName(name);
	if (path != LangManager::instance().stylesPath())
		[self switchToThemeAtPath: [NSString stringWithUTF8String: path.c_str()]];
}

+ (void)switchToThemeAtPath:(NSString*)path
{
	if (LangManager::instance().loadStyles(path.fileSystemRepresentation))
		[self notifyStylesChanged];
}

+ (void)notifyStylesChanged
{
	[NSNotificationCenter.defaultCenter postNotificationName: NppStylesChangedNotification object: nil];
}

@end
