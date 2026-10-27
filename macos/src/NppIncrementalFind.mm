#import "NppIncrementalFind.h"
#import "NppRcDialog.h"

#include "NppUpstream.h"
#include "NppSettings.h"
#include "FindReplaceDlg_rc.h"

@implementation NppIncrementalFind
{
	NppRcDialog* _owner;
	NSView* _view;
	SearchEngine* _engine;
	ScintillaView* (^_editor)(void);
	std::vector<MatchPosition> _matches;
}

- (instancetype)initWithEngine:(SearchEngine*)engine editor:(ScintillaView* (^)(void))editor
{
	if ((self = [super init]))
	{
		_engine = engine;
		_editor = [editor copy];
		_owner = [[NppRcDialog alloc] initWithWindow: nil];
		_view = [NppRcDialog viewFromRC: @"FindReplaceDlg.rc" dialog: @"IDD_INCREMENT_FIND" owner: _owner];
		[_owner show: IDC_GOUPDOWN_TOGGLE_BUTTON value: NO];
		const NppSettings& st = NppSettings::instance();
		[_owner setChecked: IDC_INCFINDMATCHCASE value: st._isIncrementalMatchCase];
		[_owner setChecked: IDC_INCFINDHILITEALL value: st._isIncrementalHighlightAll];
		[_owner setChecked: IDC_INCFINDCOUNT value: st._isIncrementalCount];
		__weak NppIncrementalFind* weakSelf = self;
		_owner.onCommand = ^BOOL(NppRcDialog* d, int cid) {
			return [weakSelf command: cid notification: d.lastNotification];
		};
	}
	return self;
}

- (NSView*)view
{
	return _view;
}

- (void)focus
{
	NSView* field = [_owner item: IDC_INCFINDTEXT];
	[field.window makeFirstResponder: field];
	[[(NSTextField*)field currentEditor] selectAll: nil];
}

- (void)searchNext:(BOOL)forward
{
	[self runSearch: YES forward: forward advance: YES highlight: NO matchCaseChanged: NO];
}

- (void)setStatus:(FindStatus)st count:(size_t)nb nth:(int)nth
{
	NSString* s = nb > 0 ? [NSString stringWithFormat: @"%d/%zu", nth, nb] : @"";
	if (st == FSNotFound)
		s = @"Phrase not found";
	else if (st == FSTopReached)
		s = nb > 0 ? [s stringByAppendingString: @" - Reached top of page, continued from bottom"] : @"Reached top of page, continued from bottom";
	else if (st == FSEndReached)
		s = nb > 0 ? [s stringByAppendingString: @" - Reached end of page, continued from top"] : @"Reached end of page, continued from top";
	[_owner setText: IDC_INCFINDSTATUS value: s];
	NSTextField* field = (NSTextField*)[_owner item: IDC_INCFINDTEXT];
	// Upstream paints the field red when the phrase isn't found.
	field.backgroundColor = st == FSNotFound ? [NSColor colorWithSRGBRed: 1 green: 0.4 blue: 0.4 alpha: 1] : NSColor.textBackgroundColor;
	field.drawsBackground = YES;
}

- (void)markInc:(BOOL)enable opt:(FindOption&)fo
{
	ScintillaView* v = _editor();
	[v message: SCI_SETINDICATORCURRENT wParam: SCE_UNIVERSAL_FOUND_STYLE_INC];
	[v message: SCI_INDICATORCLEARRANGE wParam: 0 lParam: [v message: SCI_GETLENGTH]];
	if (!enable)
		return;
	long s = [v message: SCI_GETSELECTIONSTART], e = [v message: SCI_GETSELECTIONEND];
	if (s == e)
		return;
	std::string text(e - s + 1, '\0');
	Sci_TextRangeFull tr{{s, e}, text.data()};
	[v message: SCI_GETTEXTRANGEFULL wParam: 0 lParam: reinterpret_cast<sptr_t>(&tr)];
	text.resize(e - s);
	fo._str2Search = text;
	_engine->processAll(v, ProcessMarkAll_IncSearch, fo, true);
}

- (void)runSearch:(BOOL)updateSearch forward:(BOOL)forward advance:(BOOL)advance highlight:(BOOL)updateHiLight matchCaseChanged:(BOOL)updateCase
{
	ScintillaView* v = _editor();
	FindOption fo;
	fo._isWholeWord = false;
	fo._isWrapAround = true;
	fo._incrementalType = advance ? NextIncremental : FirstIncremental;
	fo._whichDirection = forward ? DIR_DOWN : DIR_UP;
	fo._isMatchCase = [_owner isChecked: IDC_INCFINDMATCHCASE];
	std::string str2Search = [_owner text: IDC_INCFINDTEXT].UTF8String;

	if (updateSearch)
	{
		FindStatus st = FSFound;
		MatchPosition match;
		bool isFound = _engine->processFindNext(v, str2Search, fo, &st, FINDNEXTTYPE_FINDNEXT, &match);
		fo._str2Search = str2Search;
		int nth = 0;
		if ([_owner isChecked: IDC_INCFINDCOUNT])
		{
			if (_matches.empty())
				_engine->processAll(v, ProcessCountAll, fo, false, nullptr, -1, &_matches);
			for (size_t i = 0; i < _matches.size() && match.start > -1; ++i)
				if (match.start == _matches[i].start && match.end == _matches[i].end)
				{
					nth = (int)i + 1;
					break;
				}
		}
		[self setStatus: str2Search.empty() ? FSFound : st count: _matches.size() nth: nth];
		if (updateCase && !isFound)
		{
			long s = [v message: SCI_GETSELECTIONSTART];
			[v message: SCI_SETSEL wParam: (uptr_t)-1 lParam: s];
		}
	}
	if (updateHiLight)
		[self markInc: !str2Search.empty() && [_owner isChecked: IDC_INCFINDHILITEALL] opt: fo];
}

- (BOOL)command:(int)cid notification:(int)code
{
	NppSettings& s = NppSettings::instance();
	switch (cid)
	{
		case IDCANCEL:
		{
			ScintillaView* v = _editor();
			[v message: SCI_SETINDICATORCURRENT wParam: SCE_UNIVERSAL_FOUND_STYLE_INC];
			[v message: SCI_INDICATORCLEARRANGE wParam: 0 lParam: [v message: SCI_GETLENGTH]];
			_matches.clear();
			if (_onClose)
				_onClose();
			return YES;
		}
		case IDC_INCFINDPREVOK:
		case IDC_INCFINDNXTOK:
			[self runSearch: YES forward: cid == IDC_INCFINDNXTOK advance: YES highlight: NO matchCaseChanged: NO];
			return YES;
		case IDC_INCFINDMATCHCASE:
			s._isIncrementalMatchCase = [_owner isChecked: cid];
			_matches.clear();
			[self runSearch: YES forward: YES advance: NO highlight: YES matchCaseChanged: YES];
			return YES;
		case IDC_INCFINDHILITEALL:
			s._isIncrementalHighlightAll = [_owner isChecked: cid];
			[self runSearch: NO forward: YES advance: NO highlight: YES matchCaseChanged: NO];
			return YES;
		case IDC_INCFINDCOUNT:
			s._isIncrementalCount = [_owner isChecked: cid];
			_matches.clear();
			return YES;
		case IDC_INCFINDTEXT:
			if (code == 0x0300) // EN_CHANGE
			{
				_matches.clear();
				[self runSearch: YES forward: YES advance: NO highlight: [_owner isChecked: IDC_INCFINDHILITEALL] matchCaseChanged: NO];
			}
			else // Enter: next, Shift+Enter: previous
			{
				BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
				[self runSearch: YES forward: !shift advance: YES highlight: NO matchCaseChanged: NO];
			}
			return YES;
	}
	return NO;
}

@end
