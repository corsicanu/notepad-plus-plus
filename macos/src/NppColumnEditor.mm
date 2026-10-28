#import "NppColumnEditor.h"
#import "NppRcDialog.h"
#import "NppLocalization.h"

#include "NppUpstream.h"
#include "columnEditor_rc.h"

#include <algorithm>
#include <string>
#include <vector>

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	std::string format(long n, int base, bool upper)
	{
		if (n == 0)
			return "0";
		bool neg = n < 0;
		unsigned long u = neg ? -n : n;
		const char* digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
		std::string s;
		while (u)
		{
			s.insert(s.begin(), digits[u % base]);
			u /= base;
		}
		return neg ? "-" + s : s;
	}

	// Parses a field in the chosen base (getNumericFieldValueFromText); -1 when invalid.
	long parse(NSString* text, int base)
	{
		std::string s = text.UTF8String ?: "";
		if (s.empty())
			return 0;
		char* end = nullptr;
		long v = strtol(s.c_str(), &end, base);
		return (end && *end == '\0') ? v : -1;
	}

	struct Insertion { long pos; long line; };

	// Selections (rectangle or multi) in document order, else caret column on each line to the end.
	std::vector<std::pair<long, long>> targets(ScintillaView* v)
	{
		std::vector<std::pair<long, long>> t;
		long n = sci(v, SCI_GETSELECTIONS);
		if (sci(v, SCI_SELECTIONISRECTANGLE) || n > 1)
		{
			for (long i = 0; i < n; ++i)
			{
				long s = sci(v, SCI_GETSELECTIONNSTART, i), e = sci(v, SCI_GETSELECTIONNEND, i);
				// Virtual space: pad with spaces up to the column.
				long vs = sci(v, SCI_GETSELECTIONNSTARTVIRTUALSPACE, i);
				t.push_back({s, e - s + (vs << 32)});
			}
			std::sort(t.begin(), t.end());
		}
		return t;
	}
}

@implementation NppColumnEditor
{
	NppRcDialog* _dlg;
	ScintillaView* (^_editor)(void);
}

- (instancetype)initWithEditor:(ScintillaView* (^)(void))editor
{
	if ((self = [super init]))
		_editor = [editor copy];
	return self;
}

- (void)show
{
	if (!_dlg)
	{
		_dlg = [[NppRcDialog alloc] initWithRC: @"columnEditor.rc" dialog: @"IDD_COLUMNEDIT"];
		[NppLocalization applyToDialog: _dlg node: @"ColumnEditor"];
		[_dlg setItems: @[@"None", @"Zeros", @"Spaces"] forList: IDC_COL_LEADING_COMBO];
		[_dlg setItems: @[@"a-f", @"A-F"] forList: IDC_COL_HEXUC_COMBO];
		[_dlg setChecked: IDC_COL_TEXT_RADIO value: YES];
		[_dlg setChecked: IDC_COL_DEC_RADIO value: YES];
		[_dlg setText: IDC_COL_INITNUM_EDIT value: @"1"];
		[_dlg setText: IDC_COL_INCREASENUM_EDIT value: @"1"];
		[_dlg setText: IDC_COL_REPEATNUM_EDIT value: @"1"];
		__weak NppColumnEditor* weakSelf = self;
		_dlg.onCommand = ^BOOL(NppRcDialog* d, int cid) { return [weakSelf command: cid]; };
		[self updateMode];
	}
	[_dlg showModeless];
}

- (void)updateMode
{
	BOOL text = [_dlg isChecked: IDC_COL_TEXT_RADIO];
	[_dlg enable: IDC_COL_TEXT_EDIT value: text];
	for (int cid : {IDC_COL_DEC_RADIO, IDC_COL_HEX_RADIO, IDC_COL_OCT_RADIO, IDC_COL_BIN_RADIO, IDC_COL_HEXUC_COMBO,
	                IDC_COL_INITNUM_EDIT, IDC_COL_INCREASENUM_EDIT, IDC_COL_REPEATNUM_EDIT, IDC_COL_LEADING_COMBO})
		[_dlg enable: cid value: !text];
	[_dlg enable: IDC_COL_HEXUC_COMBO value: !text && [_dlg isChecked: IDC_COL_HEX_RADIO]];
}

- (int)base
{
	return [_dlg isChecked: IDC_COL_HEX_RADIO] ? 16 : [_dlg isChecked: IDC_COL_OCT_RADIO] ? 8 : [_dlg isChecked: IDC_COL_BIN_RADIO] ? 2 : 10;
}

- (BOOL)command:(int)cid
{
	switch (cid)
	{
		case IDC_COL_TEXT_RADIO:
		case IDC_COL_NUM_RADIO:
		case IDC_COL_DEC_RADIO:
		case IDC_COL_HEX_RADIO:
		case IDC_COL_OCT_RADIO:
		case IDC_COL_BIN_RADIO:
			[self updateMode];
			return YES;
		case IDOK:
			[self apply];
			return YES;
	}
	return NO;
}

// Port of ColumnEditorDlg IDOK: text or number sequence into each selection,
// or from the caret column downward when there is no column selection.
- (void)apply
{
	ScintillaView* v = _editor();
	BOOL textMode = [_dlg isChecked: IDC_COL_TEXT_RADIO];
	std::vector<std::string> values;
	int base = [self base];
	long init = 0, incr = 0, repeat = 1;
	if (!textMode)
	{
		init = parse([_dlg text: IDC_COL_INITNUM_EDIT], base);
		incr = parse([_dlg text: IDC_COL_INCREASENUM_EDIT], base);
		repeat = parse([_dlg text: IDC_COL_REPEATNUM_EDIT], base);
		if (init < 0 || incr < 0 || repeat < 0)
		{
			NSBeep();
			return;
		}
		if (repeat == 0)
			repeat = 1;
	}
	std::string text = [_dlg text: IDC_COL_TEXT_EDIT].UTF8String ?: "";
	bool upper = [_dlg selectedIndex: IDC_COL_HEXUC_COMBO] == 1;
	long leading = [_dlg selectedIndex: IDC_COL_LEADING_COMBO];

	auto sel = targets(v);
	std::vector<long> lines;
	long caretCol = 0;
	if (sel.empty())
	{
		long pos = sci(v, SCI_GETCURRENTPOS);
		caretCol = sci(v, SCI_GETCOLUMN, pos);
		long first = sci(v, SCI_LINEFROMPOSITION, pos);
		long last = sci(v, SCI_LINEFROMPOSITION, sci(v, SCI_GETLENGTH));
		for (long l = first; l <= last; ++l)
			lines.push_back(l);
	}
	size_t count = sel.empty() ? lines.size() : sel.size();

	// Number strings, padded to the widest one like upstream's "Leading" option.
	std::vector<std::string> nums(count);
	size_t width = 0;
	for (size_t i = 0; i < count; ++i)
	{
		nums[i] = textMode ? text : format(init + incr * (long)(i / repeat), base, upper);
		width = std::max(width, nums[i].size());
	}
	if (!textMode && leading > 0)
		for (auto& n : nums)
			n.insert(0, width - n.size(), leading == 1 ? '0' : ' ');

	sci(v, SCI_BEGINUNDOACTION);
	if (!sel.empty())
	{
		// Replace from the end so earlier positions stay valid.
		for (size_t i = count; i-- > 0;)
		{
			long pos = sel[i].first;
			long len = sel[i].second & 0xFFFFFFFF;
			long vs = sel[i].second >> 32;
			std::string s = std::string(vs, ' ') + nums[i];
			sci(v, SCI_SETTARGETRANGE, pos, pos + len);
			sci(v, SCI_REPLACETARGET, s.size(), reinterpret_cast<sptr_t>(s.data()));
		}
	}
	else
	{
		for (size_t i = count; i-- > 0;)
		{
			long l = lines[i];
			long lineEnd = sci(v, SCI_GETLINEENDPOSITION, l);
			long endCol = sci(v, SCI_GETCOLUMN, lineEnd);
			if (endCol < caretCol)
			{
				std::string s = std::string(caretCol - endCol, ' ') + nums[i];
				sci(v, SCI_INSERTTEXT, lineEnd, reinterpret_cast<sptr_t>(s.c_str()));
			}
			else
				sci(v, SCI_INSERTTEXT, sci(v, SCI_FINDCOLUMN, l, caretCol), reinterpret_cast<sptr_t>(nums[i].c_str()));
		}
	}
	sci(v, SCI_ENDUNDOACTION);
	[_dlg endWith: IDOK];
}

@end
