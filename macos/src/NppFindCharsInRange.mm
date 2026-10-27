#import "NppFindCharsInRange.h"
#import "NppRcDialog.h"

#include "NppUpstream.h"
#include "findCharsInRange_rc.h"

#include <string>

namespace
{
	const bool dirDown = false;

	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	// Port of FindCharsInRangeDlg::findCharInRange (works on the document's bytes).
	bool findCharInRange(ScintillaView* v, unsigned char beginRange, unsigned char endRange, intptr_t startPos, bool direction, bool wrap)
	{
		size_t totalSize = sci(v, SCI_GETLENGTH);
		if (startPos == -1)
			startPos = direction == dirDown ? 0 : totalSize - 1;
		if (startPos > static_cast<intptr_t>(totalSize))
			return false;

		const char* content = reinterpret_cast<const char*>(sci(v, SCI_GETCHARACTERPOINTER));
		bool isFound = false;
		size_t found = 0;
		auto scan = [&](int64_t from) {
			for (int64_t i = from; direction == dirDown ? i < static_cast<int64_t>(totalSize) : i >= 0; direction == dirDown ? ++i : --i)
			{
				unsigned char c = static_cast<unsigned char>(content[i]);
				if (c >= beginRange && c <= endRange)
				{
					found = static_cast<size_t>(i);
					return true;
				}
			}
			return false;
		};
		isFound = scan(startPos - (direction == dirDown ? 0 : 1));
		if (!isFound && wrap)
			isFound = scan(direction == dirDown ? 0 : totalSize - 1);

		if (isFound)
		{
			sci(v, SCI_ENSUREVISIBLE, sci(v, SCI_LINEFROMPOSITION, found));
			sci(v, SCI_GOTOPOS, found);
			sci(v, SCI_SETSEL, direction == dirDown ? found : found + 1, direction == dirDown ? found + 1 : found);
		}
		return isFound;
	}
}

@implementation NppFindCharsInRange
{
	NppRcDialog* _dlg;
	ScintillaView* (^_editor)(void);
}

- (instancetype)initWithEditor:(ScintillaView* (^)(void))editorProvider
{
	if ((self = [super init]))
		_editor = [editorProvider copy];
	return self;
}

- (void)show
{
	if (!_dlg)
	{
		_dlg = [[NppRcDialog alloc] initWithRC: @"findCharsInRange.rc" dialog: @"IDD_FINDCHARACTERS"];
		[_dlg setChecked: IDC_NONASCCI_RADIO value: YES];
		[_dlg setChecked: ID_FINDCHAR_DIRDOWN value: YES];
		[_dlg setText: IDC_RANGESTART_EDIT value: @"0"];
		[_dlg setText: IDC_RANGEEND_EDIT value: @"255"];
		[_dlg enable: IDC_RANGESTART_EDIT value: NO];
		[_dlg enable: IDC_RANGEEND_EDIT value: NO];
		__weak NppFindCharsInRange* weakSelf = self;
		_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) {
			return [weakSelf command: cid];
		};
	}
	[_dlg showModeless];
}

- (BOOL)rangeStart:(unsigned char*)start end:(unsigned char*)end
{
	if ([_dlg isChecked: IDC_NONASCCI_RADIO])
	{
		*start = 128;
		*end = 255;
		return YES;
	}
	if ([_dlg isChecked: IDC_ASCCI_RADIO])
	{
		*start = 0;
		*end = 127;
		return YES;
	}
	if ([_dlg isChecked: IDC_MYRANGE_RADIO])
	{
		NSString* s = [_dlg text: IDC_RANGESTART_EDIT];
		NSString* e = [_dlg text: IDC_RANGEEND_EDIT];
		if (!s.length || !e.length)
			return NO;
		int a = s.intValue, b = e.intValue;
		if (a < 0 || b < 0 || a > 255 || b > 255 || a > b)
			return NO;
		*start = (unsigned char)a;
		*end = (unsigned char)b;
		return YES;
	}
	return NO;
}

- (BOOL)command:(int)cid
{
	switch (cid)
	{
		case IDC_NONASCCI_RADIO:
		case IDC_ASCCI_RADIO:
			[_dlg enable: IDC_RANGESTART_EDIT value: NO];
			[_dlg enable: IDC_RANGEEND_EDIT value: NO];
			return YES;
		case IDC_MYRANGE_RADIO:
			[_dlg enable: IDC_RANGESTART_EDIT value: YES];
			[_dlg enable: IDC_RANGEEND_EDIT value: YES];
			return YES;
		case ID_FINDCHAR_NEXT:
		{
			unsigned char start = 0, end = 255;
			if (![self rangeStart: &start end: &end])
			{
				NSAlert* a = [[NSAlert alloc] init];
				a.messageText = @"Range Value problem";
				a.informativeText = @"You should type between 0 and 255.";
				[a runModal];
				return YES;
			}
			ScintillaView* v = _editor();
			findCharInRange(v, start, end, sci(v, SCI_GETCURRENTPOS), [_dlg isChecked: ID_FINDCHAR_DIRUP], [_dlg isChecked: ID_FINDCHAR_WRAP]);
			return YES;
		}
	}
	return NO;
}

@end
