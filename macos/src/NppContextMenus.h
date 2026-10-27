// Editor and tab context menus, built like NppParameters::getContextMenuFromXmlTree:
// contextMenu.xml (created from upstream's CONTEXTMENU_XML_CONTENT when
// missing) and tabContextMenu.xml or the default list from NppNotification.cpp.
#pragma once

#import <Cocoa/Cocoa.h>

@interface NppContextMenus : NSObject

+ (NSMenu*)editorContextMenu;
+ (NSMenu*)tabContextMenu;

@end
