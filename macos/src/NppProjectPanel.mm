// Project Panels 1-3: port of ProjectPanel. A workspace file is
// <NotepadPlus><Project name><Folder name><File name="relative/path"/>...,
// paths stored relative to the workspace file, as upstream.

#import "NppProjectPanel.h"
#import "NppMainWindowInternal.h"

#include "NppConfig.h"
#include "NppXml.h"
#include "ProjectPanel_rc.h"

namespace
{
	enum NodeType { nodeWorkspace, nodeProject, nodeFolder, nodeFile };

	// getRelativePath: `path` relative to the workspace file's folder.
	NSString* relativePath(NSString* path, NSString* workspaceFile)
	{
		NSArray* to = path.stringByStandardizingPath.pathComponents;
		NSArray* from = workspaceFile.stringByStandardizingPath.stringByDeletingLastPathComponent.pathComponents;
		NSUInteger i = 0;
		while (i < to.count && i < from.count && [to[i] isEqualToString: from[i]])
			++i;
		if (i <= 1) // nothing but "/" in common: keep it absolute
			return path;
		NSMutableArray* parts = [NSMutableArray array];
		for (NSUInteger k = i; k < from.count; ++k)
			[parts addObject: @".."];
		[parts addObjectsFromArray: [to subarrayWithRange: NSMakeRange(i, to.count - i)]];
		return [NSString pathWithComponents: parts];
	}

	// getAbsoluteFilePath
	NSString* absolutePath(NSString* name, NSString* workspaceFile)
	{
		name = [name stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
		if (name.isAbsolutePath || !workspaceFile.length)
			return name.stringByStandardizingPath;
		return [workspaceFile.stringByDeletingLastPathComponent stringByAppendingPathComponent: name].stringByStandardizingPath;
	}
}

@interface NppProjectNode : NSObject
@property (nonatomic) NodeType type;
@property (nonatomic, copy) NSString* name;       // label
@property (nonatomic, copy) NSString* path;       // files: absolute path
@property (nonatomic, weak) NppProjectNode* parent;
@property (nonatomic, strong) NSMutableArray<NppProjectNode*>* children;
@end

@implementation NppProjectNode

+ (instancetype)nodeOfType:(NodeType)type name:(NSString*)name
{
	NppProjectNode* n = [[NppProjectNode alloc] init];
	n.type = type;
	n.name = name;
	n.children = type == nodeFile ? nil : [NSMutableArray array];
	return n;
}

- (void)add:(NppProjectNode*)child
{
	child.parent = self;
	[_children addObject: child];
}

@end

@implementation NppProjectPanel
{
	__weak NppMainWindow* _window;
	int _index;
	NSView* _root;
	NSOutlineView* _tree;
	NppProjectNode* _workspace;
	NSString* _workSpaceFilePath;
	BOOL _isDirty;
}

- (instancetype)initWithWindow:(NppMainWindow*)window index:(int)index
{
	if ((self = [super init]))
	{
		_window = window;
		_index = index;

		NSPopUpButton* (^menuButton)(NSString*, NSMenu*) = ^(NSString* title, NSMenu* menu) {
			NSPopUpButton* b = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: YES];
			b.bezelStyle = NSBezelStyleTexturedRounded;
			b.controlSize = NSControlSizeSmall;
			b.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
			[menu insertItemWithTitle: title action: nil keyEquivalent: @"" atIndex: 0];
			b.menu = menu;
			return b;
		};
		NSStackView* bar = [NSStackView stackViewWithViews: @[
			menuButton(@"Workspace", [self workspaceMenu]),
			menuButton(@"Edit", [self editMenuFor: nil]),
		]];
		bar.spacing = 4;
		bar.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);
		bar.translatesAutoresizingMaskIntoConstraints = NO;

		_tree = [[NSOutlineView alloc] init];
		NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier: @"name"];
		[_tree addTableColumn: col];
		_tree.outlineTableColumn = col;
		_tree.headerView = nil;
		_tree.rowHeight = 18;
		_tree.dataSource = self;
		_tree.delegate = self;
		_tree.target = self;
		_tree.doubleAction = @selector(openSelectFile:);
		_tree.menu = [[NSMenu alloc] init];
		_tree.menu.delegate = self;

		NSScrollView* sv = [[NSScrollView alloc] init];
		sv.documentView = _tree;
		sv.hasVerticalScroller = YES;
		sv.autohidesScrollers = YES;
		sv.translatesAutoresizingMaskIntoConstraints = NO;

		_root = [[NSView alloc] init];
		[_root addSubview: bar];
		[_root addSubview: sv];
		[NSLayoutConstraint activateConstraints: @[
			[bar.topAnchor constraintEqualToAnchor: _root.topAnchor],
			[bar.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[bar.heightAnchor constraintEqualToConstant: 24],
			[sv.topAnchor constraintEqualToAnchor: bar.bottomAnchor constant: 2],
			[sv.leadingAnchor constraintEqualToAnchor: _root.leadingAnchor],
			[sv.trailingAnchor constraintEqualToAnchor: _root.trailingAnchor],
			[sv.bottomAnchor constraintEqualToAnchor: _root.bottomAnchor],
		]];

		// The workspace this panel had last time (<ProjectPanels>).
		NSString* last = @(NppConfig::instance().projectPanelWorkspaces[index].c_str());
		if (!last.length || ![self openWorkSpace: last])
			[self newWorkSpace];
	}
	return self;
}

- (NSString*)title
{
	// "Project Panel 1", with the workspace's dirty mark like upstream's caption.
	return [NSString stringWithFormat: @"Project Panel %d%@", _index + 1, _isDirty ? @" *" : @""];
}

- (NSView*)view { return _root; }

- (BOOL)isDirty { return _isDirty; }

- (void)setWorkSpaceDirty:(BOOL)dirty
{
	_isDirty = dirty;
	[_window.dock refreshPanel: IDM_VIEW_PROJECT_PANEL_1 + _index];   // caption shows the dirty mark
}

#pragma mark Workspace files

- (void)newWorkSpace
{
	_workspace = [NppProjectNode nodeOfType: nodeWorkspace name: @"Workspace"];
	_workSpaceFilePath = @"";
	_isDirty = NO;
	[self reloadTree];
	[self rememberWorkspace];
}

- (BOOL)openWorkSpace:(NSString*)file
{
	pugi::xml_document doc;
	if (!doc.load_file(file.fileSystemRepresentation))
		return NO;
	pugi::xml_node root = doc.child("NotepadPlus");
	if (!root)
		return NO;
	NppProjectNode* ws = [NppProjectNode nodeOfType: nodeWorkspace name: file.lastPathComponent];
	for (pugi::xml_node p = root.child("Project"); p; p = p.next_sibling("Project"))
	{
		NppProjectNode* proj = [NppProjectNode nodeOfType: nodeProject name: @(p.attribute("name").as_string(""))];
		[self buildTreeFrom: p into: proj workspace: file];
		[ws add: proj];
	}
	_workspace = ws;
	_workSpaceFilePath = file;
	_isDirty = NO;
	[self reloadTree];
	[self rememberWorkspace];
	return YES;
}

// ProjectPanel::buildTreeFrom
- (void)buildTreeFrom:(pugi::xml_node)node into:(NppProjectNode*)parent workspace:(NSString*)file
{
	for (pugi::xml_node c = node.first_child(); c; c = c.next_sibling())
	{
		if (std::strcmp(c.name(), "Folder") == 0)
		{
			NppProjectNode* f = [NppProjectNode nodeOfType: nodeFolder name: @(c.attribute("name").as_string(""))];
			[self buildTreeFrom: c into: f workspace: file];
			[parent add: f];
		}
		else if (std::strcmp(c.name(), "File") == 0)
		{
			NSString* path = absolutePath(@(c.attribute("name").as_string("")), file);
			NppProjectNode* f = [NppProjectNode nodeOfType: nodeFile name: path.lastPathComponent];
			f.path = path;
			[parent add: f];
		}
	}
}

// ProjectPanel::writeWorkSpace
- (BOOL)writeWorkSpace:(NSString*)file updateGUI:(BOOL)update
{
	pugi::xml_document doc;
	pugi::xml_node decl = doc.append_child(pugi::node_declaration);
	decl.append_attribute("version") = "1.0";
	decl.append_attribute("encoding") = "UTF-8";
	pugi::xml_node root = doc.append_child("NotepadPlus");
	for (NppProjectNode* proj in _workspace.children)
	{
		pugi::xml_node p = root.append_child("Project");
		p.append_attribute("name") = proj.name.UTF8String;
		[self buildProjectXml: p from: proj workspace: file];
	}
	if (!doc.save_file(file.fileSystemRepresentation, "    "))
	{
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = [NSString stringWithFormat: @"An error occurred while writing your workspace file.\nYour workspace has not been saved."];
		[a runModal];
		return NO;
	}
	if (update)
	{
		_workSpaceFilePath = file;
		_workspace.name = file.lastPathComponent;
		_isDirty = NO;
		[self reloadTree];
		[self rememberWorkspace];
	}
	return YES;
}

- (void)buildProjectXml:(pugi::xml_node)node from:(NppProjectNode*)parent workspace:(NSString*)file
{
	for (NppProjectNode* c in parent.children)
	{
		if (c.type == nodeFile)
			node.append_child("File").append_attribute("name") = relativePath(c.path, file).UTF8String;
		else
		{
			pugi::xml_node f = node.append_child("Folder");
			f.append_attribute("name") = c.name.UTF8String;
			[self buildProjectXml: f from: c workspace: file];
		}
	}
}

- (BOOL)saveWorkSpace
{
	if (!_workSpaceFilePath.length)
		return [self saveWorkSpaceAs: NO];
	return [self writeWorkSpace: _workSpaceFilePath updateGUI: YES];
}

- (BOOL)saveWorkSpaceAs:(BOOL)copy
{
	NSSavePanel* p = [NSSavePanel savePanel];
	p.nameFieldStringValue = _workSpaceFilePath.length ? _workSpaceFilePath.lastPathComponent : @"Workspace.xml";
	if ([p runModal] != NSModalResponseOK)
		return NO;
	return [self writeWorkSpace: p.URL.path updateGUI: !copy];
}

- (void)rememberWorkspace
{
	NppConfig::instance().projectPanelWorkspaces[_index] = _workSpaceFilePath.length ? _workSpaceFilePath.fileSystemRepresentation : "";
}

// ProjectPanel::checkIfNeedSave: asked when closing / switching workspaces.
- (BOOL)checkIfNeedSave
{
	if (!_isDirty)
		return YES;
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = @"The workspace was modified. Do you want to save it?";
	a.informativeText = self.title;
	[a addButtonWithTitle: @"Yes"];
	[a addButtonWithTitle: @"No"];
	[a addButtonWithTitle: @"Cancel"];
	NSModalResponse r = [a runModal];
	if (r == NSAlertFirstButtonReturn)
		return [self saveWorkSpace];
	return r == NSAlertSecondButtonReturn;
}

#pragma mark Tree

- (void)reloadTree
{
	[_tree reloadData];
	[_tree expandItem: _workspace];
	[_window.dock refreshPanel: IDM_VIEW_PROJECT_PANEL_1 + _index];
}

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(NppProjectNode*)item
{
	return item ? item.children.count : 1;
}

- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(NppProjectNode*)item
{
	return item ? item.children[i] : _workspace;
}

- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(NppProjectNode*)item
{
	return item.type != nodeFile;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(NppProjectNode*)item
{
	NSTableCellView* v = [ov makeViewWithIdentifier: @"proj" owner: nil];
	if (!v)
	{
		v = [[NSTableCellView alloc] init];
		v.identifier = @"proj";
		NSImageView* iv = [[NSImageView alloc] init];
		NSTextField* tf = [[NSTextField alloc] init];
		tf.bordered = NO;
		tf.drawsBackground = NO;
		tf.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
		tf.lineBreakMode = NSLineBreakByTruncatingTail;
		tf.target = self;
		tf.action = @selector(renameEdited:);
		for (NSView* sv in @[iv, tf])
		{
			sv.translatesAutoresizingMaskIntoConstraints = NO;
			[v addSubview: sv];
		}
		v.imageView = iv;
		v.textField = tf;
		[NSLayoutConstraint activateConstraints: @[
			[iv.leadingAnchor constraintEqualToAnchor: v.leadingAnchor],
			[iv.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
			[iv.widthAnchor constraintEqualToConstant: 16],
			[iv.heightAnchor constraintEqualToConstant: 16],
			[tf.leadingAnchor constraintEqualToAnchor: iv.trailingAnchor constant: 4],
			[tf.trailingAnchor constraintEqualToAnchor: v.trailingAnchor],
			[tf.centerYAnchor constraintEqualToAnchor: v.centerYAnchor],
		]];
	}
	v.textField.stringValue = item.name;
	v.textField.editable = item.type != nodeWorkspace;
	v.textField.textColor = (item.type == nodeFile && ![NSFileManager.defaultManager fileExistsAtPath: item.path]) ? NSColor.systemRedColor : NSColor.labelColor;
	switch (item.type)
	{
		case nodeWorkspace: v.imageView.image = [NSImage imageWithSystemSymbolName: @"square.stack.3d.up" accessibilityDescription: nil]; break;
		case nodeProject: v.imageView.image = [NSImage imageWithSystemSymbolName: @"shippingbox" accessibilityDescription: nil]; break;
		case nodeFolder: v.imageView.image = [NSWorkspace.sharedWorkspace iconForFileType: NSFileTypeForHFSTypeCode(kGenericFolderIcon)]; break;
		case nodeFile: v.imageView.image = [NSWorkspace.sharedWorkspace iconForFile: item.path]; break;
	}
	v.toolTip = item.type == nodeFile ? item.path : (item.type == nodeWorkspace ? _workSpaceFilePath : nil);
	return v;
}

#pragma mark Actions

- (NppProjectNode*)targetNode
{
	NSInteger row = _tree.clickedRow >= 0 ? _tree.clickedRow : _tree.selectedRow;
	return row >= 0 ? [_tree itemAtRow: row] : _workspace;
}

- (void)openSelectFile:(id)sender
{
	NppProjectNode* n = [self targetNode];
	if (n.type != nodeFile)
		return;
	if (![NSFileManager.defaultManager fileExistsAtPath: n.path])
		return;
	[_window openPaths: @[n.path]];
}

- (void)renameEdited:(NSTextField*)tf
{
	NSInteger row = [_tree rowForView: tf];
	NppProjectNode* n = row >= 0 ? [_tree itemAtRow: row] : nil;
	if (!n || !tf.stringValue.length || [tf.stringValue isEqualToString: n.name])
	{
		tf.stringValue = n.name ?: @"";
		return;
	}
	n.name = tf.stringValue;
	if (n.type == nodeFile)
	{
		NSString* newPath = [n.path.stringByDeletingLastPathComponent stringByAppendingPathComponent: n.name];
		n.path = newPath;
	}
	[self setWorkSpaceDirty: YES];
	[_tree reloadItem: n];
}

- (void)beginRename:(NppProjectNode*)n
{
	NSInteger row = [_tree rowForItem: n];
	if (row < 0)
		return;
	[_tree selectRowIndexes: [NSIndexSet indexSetWithIndex: row] byExtendingSelection: NO];
	[_tree editColumn: 0 row: row withEvent: nil select: YES];
}

- (void)addChild:(NppProjectNode*)child to:(NppProjectNode*)parent
{
	[parent add: child];
	[self setWorkSpaceDirty: YES];
	[_tree reloadItem: parent reloadChildren: YES];
	[_tree expandItem: parent];
}

- (void)addFilesTo:(NppProjectNode*)parent
{
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.allowsMultipleSelection = YES;
	if ([p runModal] != NSModalResponseOK)
		return;
	for (NSURL* u in p.URLs)
	{
		NppProjectNode* f = [NppProjectNode nodeOfType: nodeFile name: u.lastPathComponent];
		f.path = u.path;
		[parent add: f];
	}
	[self setWorkSpaceDirty: YES];
	[_tree reloadItem: parent reloadChildren: YES];
	[_tree expandItem: parent];
}

// ProjectPanel::recursiveAddFilesFrom: sub folders become Folder nodes,
// hidden entries skipped.
- (void)addFilesFromDirectory:(NSString*)dir to:(NppProjectNode*)parent
{
	NSArray<NSURL*>* urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL: [NSURL fileURLWithPath: dir]
	                                                     includingPropertiesForKeys: @[NSURLIsDirectoryKey]
	                                                                        options: NSDirectoryEnumerationSkipsHiddenFiles error: nil];
	urls = [urls sortedArrayUsingComparator: ^NSComparisonResult(NSURL* a, NSURL* b) {
		return [a.lastPathComponent localizedStandardCompare: b.lastPathComponent];
	}];
	for (NSURL* u in urls)
	{
		NSNumber* isDir = nil;
		[u getResourceValue: &isDir forKey: NSURLIsDirectoryKey error: nil];
		if (isDir.boolValue)
		{
			NppProjectNode* f = [NppProjectNode nodeOfType: nodeFolder name: u.lastPathComponent];
			[self addFilesFromDirectory: u.path to: f];
			[parent add: f];
		}
	}
	for (NSURL* u in urls)
	{
		NSNumber* isDir = nil;
		[u getResourceValue: &isDir forKey: NSURLIsDirectoryKey error: nil];
		if (!isDir.boolValue)
		{
			NppProjectNode* f = [NppProjectNode nodeOfType: nodeFile name: u.lastPathComponent];
			f.path = u.path;
			[parent add: f];
		}
	}
}

- (void)move:(NppProjectNode*)n by:(NSInteger)delta
{
	NSMutableArray* siblings = n.parent.children;
	NSUInteger i = [siblings indexOfObject: n];
	NSInteger j = (NSInteger)i + delta;
	if (i == NSNotFound || j < 0 || j >= (NSInteger)siblings.count)
		return;
	[siblings exchangeObjectAtIndex: i withObjectAtIndex: j];
	[self setWorkSpaceDirty: YES];
	[_tree reloadItem: n.parent reloadChildren: YES];
	[_tree selectRowIndexes: [NSIndexSet indexSetWithIndex: [_tree rowForItem: n]] byExtendingSelection: NO];
}

- (void)keyDown:(NSEvent*)e
{
	NppProjectNode* n = [self targetNode];
	if (e.keyCode == 51 || e.keyCode == 117) // Delete
		[self removeNode: n];
	else if ((e.modifierFlags & NSEventModifierFlagCommand) && e.keyCode == 126)
		[self move: n by: -1];
	else if ((e.modifierFlags & NSEventModifierFlagCommand) && e.keyCode == 125)
		[self move: n by: 1];
}

- (void)removeNode:(NppProjectNode*)n
{
	if (n.type == nodeWorkspace)
		return;
	if (n.type != nodeFile && n.children.count)
	{
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"All the sub-items will be removed.\nAre you sure you want to remove this folder from the project?";
		[a addButtonWithTitle: @"Yes"];
		[a addButtonWithTitle: @"No"];
		if ([a runModal] != NSAlertFirstButtonReturn)
			return;
	}
	else if (n.type == nodeFile)
	{
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"Are you sure you want to remove this file from the project?";
		[a addButtonWithTitle: @"Yes"];
		[a addButtonWithTitle: @"No"];
		if ([a runModal] != NSAlertFirstButtonReturn)
			return;
	}
	NppProjectNode* parent = n.parent;
	[parent.children removeObject: n];
	[self setWorkSpaceDirty: YES];
	[_tree reloadItem: parent reloadChildren: YES];
}

#pragma mark Menus (ProjectPanel::initMenus)

- (NSMenuItem*)item:(NSString*)title tag:(int)tag node:(NppProjectNode*)n
{
	NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle: title action: @selector(popupMenuCmd:) keyEquivalent: @""];
	mi.target = self;
	mi.tag = tag;
	mi.representedObject = n;
	return mi;
}

- (NSMenu*)workspaceMenu
{
	NSMenu* m = [[NSMenu alloc] init];
	for (NSMenuItem* mi in @[
		[self item: @"New Workspace" tag: IDM_PROJECT_NEWWS node: nil],
		[self item: @"Open Workspace" tag: IDM_PROJECT_OPENWS node: nil],
		[self item: @"Reload Workspace" tag: IDM_PROJECT_RELOADWS node: nil],
		[self item: @"Save" tag: IDM_PROJECT_SAVEWS node: nil],
		[self item: @"Save As..." tag: IDM_PROJECT_SAVEASWS node: nil],
		[self item: @"Save a Copy As..." tag: IDM_PROJECT_SAVEACOPYASWS node: nil],
		NSMenuItem.separatorItem,
		[self item: @"Add New Project" tag: IDM_PROJECT_NEWPROJECT node: nil],
		NSMenuItem.separatorItem,
		[self item: @"Find in Projects..." tag: IDM_PROJECT_FINDINPROJECTSWS node: nil],
	])
		[m addItem: mi];
	return m;
}

// Edit menu / context menu for the selected node (project, folder or file).
- (NSMenu*)editMenuFor:(NppProjectNode*)n
{
	NSMenu* m = [[NSMenu alloc] init];
	m.delegate = n ? nil : self;
	if (!n)
		return m;   // the toolbar's Edit menu is filled when opened
	NSMutableArray* items = [NSMutableArray array];
	if (n.type == nodeWorkspace)
		return [self workspaceMenu];
	[items addObjectsFromArray: @[
		[self item: @"Move Up" tag: IDM_PROJECT_MOVEUP node: n],
		[self item: @"Move Down" tag: IDM_PROJECT_MOVEDOWN node: n],
		NSMenuItem.separatorItem,
		[self item: @"Rename" tag: IDM_PROJECT_RENAME node: n],
	]];
	if (n.type == nodeFile)
	{
		[items addObject: [self item: @"Remove" tag: IDM_PROJECT_DELETEFILE node: n]];
		[items addObject: [self item: @"Modify File Path" tag: IDM_PROJECT_MODIFYFILEPATH node: n]];
	}
	else
	{
		[items addObjectsFromArray: @[
			[self item: @"Add Folder" tag: IDM_PROJECT_NEWFOLDER node: n],
			[self item: @"Add Files..." tag: IDM_PROJECT_ADDFILES node: n],
			[self item: @"Add Files from Directory..." tag: IDM_PROJECT_ADDFILESRECUSIVELY node: n],
			[self item: @"Remove" tag: IDM_PROJECT_DELETEFOLDER node: n],
		]];
	}
	for (NSMenuItem* mi in items)
		[m addItem: mi];
	return m;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	if (menu == _tree.menu)
	{
		[menu removeAllItems];
		NppProjectNode* n = _tree.clickedRow >= 0 ? [_tree itemAtRow: _tree.clickedRow] : _workspace;
		for (NSMenuItem* mi in [self editMenuFor: n].itemArray)
			[menu addItem: [mi copy]];
		return;
	}
	// Toolbar Edit menu: keep the pull-down title item, then the selection's items.
	while (menu.numberOfItems > 1)
		[menu removeItemAtIndex: 1];
	NSInteger row = _tree.selectedRow;
	NppProjectNode* n = row >= 0 ? [_tree itemAtRow: row] : nil;
	if (!n || n.type == nodeWorkspace)
		return;
	for (NSMenuItem* mi in [self editMenuFor: n].itemArray)
		[menu addItem: [mi copy]];
}

// ProjectPanel::popupMenuCmd
- (void)popupMenuCmd:(NSMenuItem*)mi
{
	NppProjectNode* n = mi.representedObject ?: [self targetNode];
	switch (mi.tag)
	{
		case IDM_PROJECT_NEWPROJECT:
		{
			NppProjectNode* p = [NppProjectNode nodeOfType: nodeProject name: @"Project Name"];
			[self addChild: p to: _workspace];
			[self beginRename: p];
			break;
		}
		case IDM_PROJECT_NEWWS:
			if ([self checkIfNeedSave])
				[self newWorkSpace];
			break;
		case IDM_PROJECT_OPENWS:
		{
			if (![self checkIfNeedSave])
				break;
			NSOpenPanel* p = [NSOpenPanel openPanel];
			if ([p runModal] == NSModalResponseOK && ![self openWorkSpace: p.URL.path])
			{
				NSAlert* a = [[NSAlert alloc] init];
				a.messageText = @"The workspace could not be opened.\nIt seems the file to open is not a valid project file.";
				[a runModal];
			}
			break;
		}
		case IDM_PROJECT_RELOADWS:
		{
			if (_isDirty)
			{
				NSAlert* a = [[NSAlert alloc] init];
				a.messageText = @"The current workspace was modified. Reloading will discard all modifications.\nDo you want to continue?";
				[a addButtonWithTitle: @"Yes"];
				[a addButtonWithTitle: @"No"];
				if ([a runModal] != NSAlertFirstButtonReturn)
					break;
			}
			if ([NSFileManager.defaultManager fileExistsAtPath: _workSpaceFilePath])
				[self openWorkSpace: _workSpaceFilePath];
			else
			{
				NSAlert* a = [[NSAlert alloc] init];
				a.messageText = @"Cannot find the file to reload.";
				[a runModal];
			}
			break;
		}
		case IDM_PROJECT_SAVEWS: [self saveWorkSpace]; break;
		case IDM_PROJECT_SAVEASWS: [self saveWorkSpaceAs: NO]; break;
		case IDM_PROJECT_SAVEACOPYASWS: [self saveWorkSpaceAs: YES]; break;
		case IDM_PROJECT_FINDINPROJECTSWS:
			[_window findInFilesInDirectory: _workSpaceFilePath.stringByDeletingLastPathComponent ?: @""];
			break;
		case IDM_PROJECT_RENAME: [self beginRename: n]; break;
		case IDM_PROJECT_NEWFOLDER:
		{
			NppProjectNode* f = [NppProjectNode nodeOfType: nodeFolder name: @"Folder Name"];
			[self addChild: f to: n];
			[self beginRename: f];
			break;
		}
		case IDM_PROJECT_ADDFILES: [self addFilesTo: n]; break;
		case IDM_PROJECT_ADDFILESRECUSIVELY:
		{
			NSOpenPanel* p = [NSOpenPanel openPanel];
			p.canChooseDirectories = YES;
			p.canChooseFiles = NO;
			if ([p runModal] != NSModalResponseOK)
				break;
			[self addFilesFromDirectory: p.URL.path to: n];
			[self setWorkSpaceDirty: YES];
			[_tree reloadItem: n reloadChildren: YES];
			[_tree expandItem: n];
			break;
		}
		case IDM_PROJECT_DELETEFOLDER:
		case IDM_PROJECT_DELETEFILE:
			[self removeNode: n];
			break;
		case IDM_PROJECT_MODIFYFILEPATH:
		{
			NSOpenPanel* p = [NSOpenPanel openPanel];
			p.directoryURL = [NSURL fileURLWithPath: n.path.stringByDeletingLastPathComponent];
			if ([p runModal] != NSModalResponseOK)
				break;
			n.path = p.URL.path;
			n.name = p.URL.lastPathComponent;
			[self setWorkSpaceDirty: YES];
			[_tree reloadItem: n];
			break;
		}
		case IDM_PROJECT_MOVEUP: [self move: n by: -1]; break;
		case IDM_PROJECT_MOVEDOWN: [self move: n by: 1]; break;
	}
}

@end
