// Session restore, snapshot backups ("periodic backup"), settings applied
// to the editor, and detection of files changed outside Notepad++.
// Ports of Notepad_plus::loadSession / getCurrentOpenedFiles,
// FileManager::backupCurrentBuffer and Notepad_plus::doReload/doDelete
// prompts.

#import "NppMainWindowInternal.h"

#include "LangManager.h"
#include "NppUdl.h"
#include "NppConfig.h"
#include "NppSettings.h"
#include "NppUpstream.h"

@implementation NppMainWindow (Session)

#pragma mark - Settings -> editor

// Port of the relevant parts of ScintillaEditView::init / Notepad_plus::loadGUIConfig.
- (void)applySettingsToEditor:(ScintillaView*)e
{
	const NppSettings& s = NppSettings::instance();
	[e message: SCI_SETTABWIDTH wParam: s._tabSize];
	[e message: SCI_SETUSETABS wParam: !s._tabReplaceBySpace];
	[e message: SCI_SETBACKSPACEUNINDENTS wParam: s._backspaceUnindent];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_SYMBOL lParam: s._bookMarkMarginShow ? 16 : 0];
	[e message: SCI_SETINDENTATIONGUIDES wParam: s._indentGuideLineShow ? SC_IV_LOOKBOTH : SC_IV_NONE];
	[e message: SCI_SETVIEWWS wParam: s._whiteSpaceShow ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
	[e message: SCI_SETVIEWEOL wParam: s._eolShow];
	[e message: SCI_SETZOOM wParam: s._zoom];
	[e message: SCI_SETVIRTUALSPACEOPTIONS wParam: SCVS_RECTANGULARSELECTION | (s._virtualSpace ? SCVS_USERACCESSIBLE : 0)];
	[e message: SCI_SETENDATLASTLINE wParam: !s._scrollBeyondLastLine];
	[e message: SCI_SETMULTIPLESELECTION wParam: s._multiSelection];
	[e message: SCI_SETCARETWIDTH wParam: s._caretWidth];
	[e message: SCI_SETCARETPERIOD wParam: s._caretBlinkRate];
	[e message: SCI_SETCARETLINEVISIBLE wParam: s._currentLineIndicator != 0];
	[e message: SCI_SETCARETLINEFRAME wParam: s._currentLineIndicator == 2 ? s._currentLineFrameWidth : 0];
	[e message: SCI_SETWRAPINDENTMODE wParam: s._lineWrapMethod == "aligned" ? SC_WRAPINDENT_SAME : s._lineWrapMethod == "indent" ? SC_WRAPINDENT_INDENT : SC_WRAPINDENT_FIXED];

	int ch = s._isChangeHistoryEnabled;
	[e message: SCI_SETCHANGEHISTORY wParam: ch == 0 ? SC_CHANGE_HISTORY_DISABLED
		: SC_CHANGE_HISTORY_ENABLED | ((ch & 1) ? SC_CHANGE_HISTORY_MARKERS : 0) | ((ch & 2) ? SC_CHANGE_HISTORY_INDICATORS : 0)];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_CHANGEHISTORY lParam: (ch & 1) ? 9 : 0];

	// Fold margin style (ScintillaEditView::setMakerStyle).
	const std::string& fs = s._folderMarkStyle;
	int open, closed, sub, tail, end, openMid, midTail;
	if (fs == "simple")       { open = SC_MARK_MINUS; closed = SC_MARK_PLUS; sub = tail = end = openMid = midTail = SC_MARK_EMPTY; }
	else if (fs == "arrow")   { open = SC_MARK_ARROWDOWN; closed = SC_MARK_ARROW; sub = tail = end = openMid = midTail = SC_MARK_EMPTY; }
	else if (fs == "circle")  { open = SC_MARK_CIRCLEMINUS; closed = SC_MARK_CIRCLEPLUS; sub = SC_MARK_VLINE; tail = SC_MARK_LCORNERCURVE;
	                            end = SC_MARK_CIRCLEPLUSCONNECTED; openMid = SC_MARK_CIRCLEMINUSCONNECTED; midTail = SC_MARK_TCORNERCURVE; }
	else                      { open = SC_MARK_BOXMINUS; closed = SC_MARK_BOXPLUS; sub = SC_MARK_VLINE; tail = SC_MARK_LCORNER;
	                            end = SC_MARK_BOXPLUSCONNECTED; openMid = SC_MARK_BOXMINUSCONNECTED; midTail = SC_MARK_TCORNER; }
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPEN lParam: open];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDER lParam: closed];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERSUB lParam: sub];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERTAIL lParam: tail];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEREND lParam: end];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDEROPENMID lParam: openMid];
	[e message: SCI_MARKERDEFINE wParam: SC_MARKNUM_FOLDERMIDTAIL lParam: midTail];
	[e message: SCI_SETMARGINWIDTHN wParam: MARGIN_FOLD lParam: fs == "none" ? 0 : 14];

	self.wordWrap = s._wrap;
	[e message: SCI_SETWRAPMODE wParam: s._wrap ? SC_WRAP_WORD : SC_WRAP_NONE];
}

// Editor state -> settings, saved in config.xml on exit.
- (void)captureEditorSettings
{
	NppSettings& s = NppSettings::instance();
	ScintillaView* e = self.editor;
	s._whiteSpaceShow = [e message: SCI_GETVIEWWS] != SCWS_INVISIBLE;
	s._eolShow = [e message: SCI_GETVIEWEOL];
	s._indentGuideLineShow = [e message: SCI_GETINDENTATIONGUIDES] != SC_IV_NONE;
	s._zoom = (int)[e message: SCI_GETZOOM];
	s._wrap = self.wordWrap;

	NppConfig& c = NppConfig::instance();
	NSRect f = self.window.frame;
	NSRect screen = self.window.screen.frame;
	c.appX = (int)f.origin.x;
	c.appY = (int)(NSMaxY(screen) - NSMaxY(f)); // top-left origin, as on Windows
	c.appW = (int)f.size.width;
	c.appH = (int)f.size.height;
	c.appMaximized = self.window.zoomed;
}

- (void)restoreWindowFrame
{
	NppConfig& c = NppConfig::instance();
	if (!c.appPositionValid)
		return;
	NSRect screen = NSScreen.mainScreen.frame;
	NSRect f = NSMakeRect(c.appX, NSMaxY(screen) - c.appY - c.appH, c.appW, c.appH);
	if (NSIntersectsRect(f, NSScreen.mainScreen.visibleFrame))
		[self.window setFrame: f display: NO];
	if (c.appMaximized)
		[self.window zoom: nil];
}

#pragma mark - Session

- (NSString*)backupDirectory
{
	const NppSettings& s = NppSettings::instance();
	std::string dir = (s._useCustomBackupDir && !s._backupDir.empty()) ? s._backupDir : NppConfig::instance().backupDir();
	NSString* d = [NSString stringWithUTF8String: dir.c_str()];
	[NSFileManager.defaultManager createDirectoryAtPath: d withIntermediateDirectories: YES attributes: nil error: nil];
	return d;
}

// Port of FileManager::backupCurrentBuffer: "<name>@<yyyy-mm-dd_hhmmss>".
- (void)writeBackupFor:(NppBuffer*)b
{
	if (!b.dirty)
	{
		if (b.backupPath)
		{
			[NSFileManager.defaultManager removeItemAtPath: b.backupPath error: nil];
			b.backupPath = nil;
		}
		return;
	}
	if (!b.backupPath)
	{
		NSDateFormatter* f = [[NSDateFormatter alloc] init];
		f.dateFormat = @"yyyy-MM-dd_HHmmss";
		NSString* name = [NSString stringWithFormat: @"%@@%@", b.displayName, [f stringFromDate: [NSDate date]]];
		b.backupPath = [[self backupDirectory] stringByAppendingPathComponent: name];
	}
	NppBuffer* cur = [self currentBuffer];
	ScintillaView* v = self.editor;
	if (b != cur)
	{
		v = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 10, 10)];
		[v message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
	}
	[[b bytesForSavingFrom: v] writeToFile: b.backupPath atomically: YES];
	if (b != cur)
		[v message: SCI_SETDOCPOINTER wParam: 0 lParam: 0];
}

- (void)snapshotTick:(NSTimer*)t
{
	const NppSettings& s = NppSettings::instance();
	if (!s._isSnapshotMode || !s._rememberLastSession)
		return;
	for (NppBuffer* b in [self allBuffers])
		[self writeBackupFor: b];
}

- (void)startSnapshotTimer
{
	const NppSettings& s = NppSettings::instance();
	NSTimeInterval interval = MAX(s._snapshotBackupTiming, 1000) / 1000.0;
	[NSTimer scheduledTimerWithTimeInterval: interval target: self selector: @selector(snapshotTick:) userInfo: nil repeats: YES];
	[NSTimer scheduledTimerWithTimeInterval: 2.0 target: self selector: @selector(checkModifiedFiles) userInfo: nil repeats: YES];
}

- (Session)currentSession:(BOOL)withBackups
{
	Session session;
	[self saveCurrentViewState];
	int active = [self activeView];
	session.activeView = active;
	for (int view = 0; view < 2; ++view)
	{
	if (![self paneVisible: view])
		continue;
	[self loadPane: view];
	auto& files = view == 0 ? session.mainViewFiles : session.subViewFiles;
	for (NppBuffer* b in self.buffers)
	{
		if (!b.path && !(withBackups && b.dirty))
			continue; // pristine untitled tabs aren't remembered
		if (withBackups)
			[self writeBackupFor: b];
		SessionFileInfo fi;
		fi.fileName = (b.path ?: b.displayName).UTF8String;
		fi.backupFilePath = withBackups && b.backupPath ? b.backupPath.UTF8String : "";
		fi.langName = b.userLangName ? b.userLangName.UTF8String : (b.lang ? b.lang->displayName : "Normal text");
		fi.encoding = b.encoding;
		fi.firstVisibleLine = b.firstVisibleLine;
		fi.startPos = b.anchorPos;
		fi.endPos = b.caretPos;
		fi.userReadOnly = b.readOnly;
		fi.untitleTabRenamed = !b.path && ![b.untitledName hasPrefix: @"new "];
		fi.tabColour = b.tabColor;
		fi.tabPinned = b.pinned;
		fi.originalFileLastModifTimestamp = (long long)(b.lastModified.timeIntervalSince1970 * 10000000.0) + 116444736000000000LL;
		ScintillaView* v = self.editor;
		BOOL attached = b == [self currentBuffer];
		if (!attached)
		{
			v = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 10, 10)];
			[v message: SCI_SETDOCPOINTER wParam: 0 lParam: reinterpret_cast<sptr_t>(b.document)];
		}
		for (long l = [v message: SCI_MARKERNEXT wParam: 0 lParam: 1 << MARK_BOOKMARK]; l >= 0;
		     l = [v message: SCI_MARKERNEXT wParam: l + 1 lParam: 1 << MARK_BOOKMARK])
			fi.marks.push_back(l);
		if (attached)
		{
			long n = [v message: SCI_GETLINECOUNT];
			for (long l = 0; l < n; ++l)
				if (([v message: SCI_GETFOLDLEVEL wParam: l] & SC_FOLDLEVELHEADERFLAG) && ![v message: SCI_GETFOLDEXPANDED wParam: l])
					fi.folds.push_back(l);
		}
		else
			[v message: SCI_SETDOCPOINTER wParam: 0 lParam: 0];
		if (b == [self currentBuffer])
			(view == 0 ? session.activeMainIndex : session.activeSubIndex) = (int)files.size();
		files.push_back(fi);
	}
	}
	[self loadPane: active];
	if (session.subViewFiles.empty())
		session.activeView = 0;
	return session;
}

- (void)saveSessionToPath:(NSString*)path withBackups:(BOOL)withBackups
{
	NppConfig::saveSession(path.fileSystemRepresentation, [self currentSession: withBackups]);
}

// Port of Notepad_plus::loadSession: main view, then sub view (a document
// listed in both views is a clone sharing one buffer).
- (void)loadSessionFromPath:(NSString*)path
{
	Session session;
	if (!NppConfig::loadSession(path.fileSystemRepresentation, session))
		return;
	[self switchToPane: 0];
	[self loadSessionFiles: session.mainViewFiles active: session.activeMainIndex mainView: nil];
	if (!session.subViewFiles.empty())
	{
		NSArray<NppBuffer*>* main = [self.buffers copy];
		[self saveCurrentViewState];
		[self showPane: 1];
		[self loadPane: 1];
		[self loadSessionFiles: session.subViewFiles active: session.activeSubIndex mainView: main];
		if (self.buffers.count == 0)
		{
			[self loadPane: 0];
			[self hidePane: 1];
		}
		else if (session.activeView != 1)
			[self switchToPane: 0];
		[self refreshAllTabs];
	}
}

- (void)loadSessionFiles:(const std::vector<SessionFileInfo>&)files active:(int)activeIndex mainView:(NSArray<NppBuffer*>*)main
{
	NSInteger active = -1;
	for (size_t i = 0; i < files.size(); ++i)
	{
		const SessionFileInfo& fi = files[i];
		NSString* file = [NSString stringWithUTF8String: fi.fileName.c_str()];
		NSString* backup = fi.backupFilePath.empty() ? nil : [NSString stringWithUTF8String: fi.backupFilePath.c_str()];
		BOOL hasBackup = backup && [NSFileManager.defaultManager fileExistsAtPath: backup];
		BOOL exists = [file hasPrefix: @"/"] && [NSFileManager.defaultManager fileExistsAtPath: file];

		NppBuffer* clone = nil;
		for (NppBuffer* m in main)
			if ((m.path && [m.path isEqualToString: file]) || (!m.path && [m.displayName isEqualToString: file]))
				clone = m;
		if (clone)
		{
			[self.buffers addObject: clone];
			NSInteger idx = self.buffers.count - 1;
			if ((int)i == activeIndex)
				active = idx;
			continue;
		}
		if (!exists && !hasBackup)
			continue;

		NppBuffer* b = [self openSessionFile: file backup: hasBackup ? backup : nil encoding: fi.encoding];
		if (!b)
			continue;
		if (const NppLang* lang = [self languageNamed: fi.langName])
		{
			b.lang = lang;
			b.userLangName = nil;
		}
		else if (NppUdlManager::instance().byName(fi.langName))
		{
			b.lang = nullptr;
			b.userLangName = @(fi.langName.c_str());
		}
		b.readOnly = fi.userReadOnly;
		b.tabColor = fi.tabColour;
		b.pinned = fi.tabPinned;
		b.firstVisibleLine = fi.firstVisibleLine;
		b.anchorPos = fi.startPos;
		b.caretPos = fi.endPos;
		NSInteger idx = [self.buffers indexOfObject: b];
		if ((int)i == activeIndex)
			active = idx;
		[self activateBuffer: idx];
		for (long m : fi.marks)
			[self.editor message: SCI_MARKERADD wParam: m lParam: MARK_BOOKMARK];
		[self.editor message: SCI_COLOURISE wParam: 0 lParam: -1];
		for (long f : fi.folds)
			[self.editor message: SCI_FOLDLINE wParam: f lParam: SC_FOLDACTION_CONTRACT];
	}
	if (active < 0 && self.buffers.count)
		active = 0;
	if (active >= 0)
		[self activateBuffer: active];
}

- (const NppLang*)languageNamed:(const std::string&)name
{
	if (name.empty())
		return nullptr;
	for (const auto& l : LangManager::instance().languages())
		if (l.displayName == name || l.name == name)
			return &l;
	return nullptr;
}

#pragma mark - External modifications

// Port of Notepad_plus::doReload / doDelete prompts, driven by a timer and app activation.
- (void)checkModifiedFiles
{
	static BOOL busy = NO;
	const NppSettings& s = NppSettings::instance();
	if (busy || !(s._fileAutoDetection & (cdEnabled4AllFiles | cdEnabled4CurrentFile)) || !NSApp.isActive)
		return;
	busy = YES;
	NSArray* list = (s._fileAutoDetection & cdEnabled4AllFiles) ? [self allBuffers] : ([self currentBuffer] ? @[[self currentBuffer]] : @[]);
	for (NppBuffer* b in list)
	{
		if (!b.path || ![[self allBuffers] containsObject: b])
			continue;
		if ([b fileDeleted])
		{
			if (b.dirty && !b.lastModified)
				continue;
			NSAlert* a = [[NSAlert alloc] init];
			a.messageText = [NSString stringWithFormat: @"The file \"%@\" doesn't exist anymore.\nKeep this file in editor?", b.path];
			[a addButtonWithTitle: @"Yes"];
			[a addButtonWithTitle: @"No"];
			b.lastModified = nil; // ask only once
			if ([a runModal] == NSAlertSecondButtonReturn)
			{
				while ([self revealBuffer: b])
					[self closeBufferAtIndex: self.currentIndex force: YES];
			}
			else
			{
				b.dirty = YES;
				[self refreshAllTabs];
			}
			continue;
		}
		if (![b fileChangedOnDisk])
			continue;
		[b updateTimestamp];
		BOOL autoUpdate = (s._fileAutoDetection & cdAutoUpdate) && !b.dirty;
		if (!autoUpdate)
		{
			NSAlert* a = [[NSAlert alloc] init];
			a.messageText = b.dirty
				? [NSString stringWithFormat: @"%@\n\nThis file has been modified by another program.\nDo you want to reload it and lose the changes made in Notepad++?", b.path]
				: [NSString stringWithFormat: @"%@\n\nThis file has been modified by another program.\nDo you want to reload it?", b.path];
			[a addButtonWithTitle: @"Yes"];
			[a addButtonWithTitle: @"No"];
			if ([a runModal] != NSAlertFirstButtonReturn)
				continue;
		}
		[self revealBuffer: b];
		b.dirty = NO;
		[self reloadCurrent];
		if (s._fileAutoDetection & cdGo2end)
			[self.editor message: SCI_DOCUMENTEND];
	}
	busy = NO;
}

@end
