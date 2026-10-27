#import "NppRcDialog.h"

#import <objc/runtime.h>

#include <windows.h>

#include <map>
#include <string>
#include <vector>

namespace
{
	// Dialog units -> points. Win32 dialogs use 8pt MS Shell Dlg; Cocoa
	// controls are taller, so scale a little more vertically.
	const CGFloat kDluX = 1.7;
	const CGFloat kDluY = 1.85;

	NSString* rcDirectory()
	{
		return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent: @"rc"];
	}

	std::string trim(const std::string& s)
	{
		size_t b = s.find_first_not_of(" \t\r\n");
		size_t e = s.find_last_not_of(" \t\r\n");
		return b == std::string::npos ? "" : s.substr(b, e - b + 1);
	}

	// ---- #define resolution -------------------------------------------------

	std::map<std::string, std::string>& defines()
	{
		static std::map<std::string, std::string> d;
		static bool loaded = false;
		if (loaded)
			return d;
		loaded = true;
		d["IDOK"] = "1";
		d["IDCANCEL"] = "2";
		d["IDYES"] = "6";
		d["IDNO"] = "7";
		d["IDC_STATIC"] = "-1";
		d["IDHELP"] = "9";
		NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath: rcDirectory() error: nil];
		for (NSString* f in files)
		{
			if (![f hasSuffix: @".h"])
				continue;
			NSString* text = [NSString stringWithContentsOfFile: [rcDirectory() stringByAppendingPathComponent: f] encoding: NSUTF8StringEncoding error: nil]
			                 ?: [NSString stringWithContentsOfFile: [rcDirectory() stringByAppendingPathComponent: f] encoding: NSWindowsCP1252StringEncoding error: nil];
			for (NSString* line in [text componentsSeparatedByString: @"\n"])
			{
				std::string l = trim(line.UTF8String);
				if (l.empty() || l[0] != '#')
					continue;
				l = trim(l.substr(1));          // "# define X" is valid too
				if (l.rfind("define", 0) != 0)
					continue;
				size_t c = l.find("//");
				if (c != std::string::npos)
					l = l.substr(0, c);
				l = trim(l.substr(6));
				size_t sp = l.find_first_of(" \t");
				if (sp == std::string::npos)
					continue;
				std::string name = l.substr(0, sp);
				std::string expr = trim(l.substr(sp));
				if (!d.count(name))
					d[name] = expr;
			}
		}
		return d;
	}

	struct Eval
	{
		const std::string& s;
		size_t i = 0;
		int depth;
		bool ok = true;

		void ws() { while (i < s.size() && isspace((unsigned char)s[i])) ++i; }

		long primary();
		long unary()
		{
			ws();
			if (i < s.size() && s[i] == '-') { ++i; return -unary(); }
			if (i < s.size() && s[i] == '+') { ++i; return unary(); }
			return primary();
		}
		long term()
		{
			long v = unary();
			for (;;)
			{
				ws();
				if (i < s.size() && s[i] == '*') { ++i; v *= unary(); }
				else return v;
			}
		}
		long sum()
		{
			long v = term();
			for (;;)
			{
				ws();
				if (i < s.size() && s[i] == '+') { ++i; v += term(); }
				else if (i < s.size() && s[i] == '-') { ++i; v -= term(); }
				else if (i < s.size() && s[i] == '|') { ++i; v |= term(); }
				else return v;
			}
		}
	};

	long resolve(const std::string& name, int depth);

	long Eval::primary()
	{
		ws();
		if (i >= s.size()) { ok = false; return 0; }
		if (s[i] == '(')
		{
			++i;
			long v = sum();
			ws();
			if (i < s.size() && s[i] == ')')
				++i;
			return v;
		}
		if (isdigit((unsigned char)s[i]))
		{
			size_t end = 0;
			long v = std::stol(s.substr(i), &end, 0);
			i += end;
			while (i < s.size() && (s[i] == 'L' || s[i] == 'l' || s[i] == 'U' || s[i] == 'u'))
				++i;
			return v;
		}
		if (isalpha((unsigned char)s[i]) || s[i] == '_')
		{
			size_t b = i;
			while (i < s.size() && (isalnum((unsigned char)s[i]) || s[i] == '_'))
				++i;
			return resolve(s.substr(b, i - b), depth + 1);
		}
		ok = false;
		return 0;
	}

	long resolve(const std::string& name, int depth)
	{
		static std::map<std::string, long> cache;
		auto c = cache.find(name);
		if (c != cache.end())
			return c->second;
		if (depth > 32)
			return -1;
		auto& d = defines();
		auto it = d.find(name);
		if (it == d.end())
			return -1;
		Eval e{it->second, 0, depth};
		long v = e.sum();
		if (!e.ok)
			v = -1;
		cache[name] = v;
		return v;
	}

	// ---- .rc statements ------------------------------------------------------

	struct RcControl
	{
		std::string kind;     // CONTROL, LTEXT, EDITTEXT, ...
		std::string text;
		std::string idName;
		std::string cls;      // for CONTROL
		std::string style;
		int x = 0, y = 0, w = 0, h = 0;
	};

	struct RcDialog
	{
		int w = 0, h = 0;
		std::string caption;
		std::vector<RcControl> controls;
	};

	// Splits "a, "b,c", d | e" on top-level commas.
	std::vector<std::string> splitArgs(const std::string& s)
	{
		std::vector<std::string> out;
		std::string cur;
		bool inQ = false;
		for (size_t i = 0; i < s.size(); ++i)
		{
			char ch = s[i];
			if (ch == '"')
			{
				if (inQ && i + 1 < s.size() && s[i + 1] == '"')
				{
					cur += "\"\"";
					++i;
					continue;
				}
				inQ = !inQ;
				cur += ch;
			}
			else if (ch == ',' && !inQ)
			{
				out.push_back(trim(cur));
				cur.clear();
			}
			else
				cur += ch;
		}
		out.push_back(trim(cur));
		return out;
	}

	std::string unquote(const std::string& s)
	{
		std::string t = trim(s);
		if (t.size() >= 2 && t.front() == '"' && t.back() == '"')
			t = t.substr(1, t.size() - 2);
		std::string out;
		for (size_t i = 0; i < t.size(); ++i)
		{
			if (t[i] == '"' && i + 1 < t.size() && t[i + 1] == '"')
			{
				out += '"';
				++i;
			}
			else if (t[i] == '\\' && i + 1 < t.size() && t[i + 1] == 'n')
			{
				out += '\n';
				++i;
			}
			else
				out += t[i];
		}
		return out;
	}

	int num(const std::string& s)
	{
		Eval e{s, 0, 0};
		return (int)e.sum();
	}

	bool parseDialog(NSString* rcFile, NSString* dialogName, RcDialog& dlg)
	{
		NSString* path = [rcDirectory() stringByAppendingPathComponent: rcFile];
		NSString* text = [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil]
		                 ?: [NSString stringWithContentsOfFile: path encoding: NSWindowsCP1252StringEncoding error: nil];
		if (!text)
			return false;

		std::vector<std::string> lines;
		for (NSString* l in [text componentsSeparatedByCharactersInSet: NSCharacterSet.newlineCharacterSet])
			lines.push_back(l.UTF8String);

		std::string header = std::string(dialogName.UTF8String);
		size_t i = 0;
		for (; i < lines.size(); ++i)
		{
			std::string t = trim(lines[i]);
			if (t.rfind(header + " DIALOG", 0) == 0)
				break;
		}
		if (i == lines.size())
			return false;

		{
			std::string t = trim(lines[i]);
			auto args = splitArgs(t.substr(t.find_first_of(" \t", header.size() + 1)));
			if (args.size() >= 4)
			{
				dlg.w = num(args[2]);
				dlg.h = num(args[3]);
			}
		}

		// Header statements until BEGIN.
		for (++i; i < lines.size(); ++i)
		{
			std::string t = trim(lines[i]);
			if (t == "BEGIN" || t == "{")
				break;
			if (t.rfind("CAPTION", 0) == 0)
				dlg.caption = unquote(t.substr(7));
		}

		// Controls until END, joining continuation lines.
		std::string stmt;
		auto flush = [&]() {
			std::string s = trim(stmt);
			stmt.clear();
			if (s.empty())
				return;
			size_t sp = s.find_first_of(" \t");
			RcControl c;
			c.kind = s.substr(0, sp);
			auto a = splitArgs(sp == std::string::npos ? "" : s.substr(sp));
			auto rect = [&](size_t at) {
				if (a.size() >= at + 4)
				{
					c.x = num(a[at]);
					c.y = num(a[at + 1]);
					c.w = num(a[at + 2]);
					c.h = num(a[at + 3]);
				}
			};
			if (c.kind == "CONTROL")
			{
				if (a.size() < 8)
					return;
				c.text = unquote(a[0]);
				c.idName = a[1];
				c.cls = unquote(a[2]);
				c.style = a[3];
				rect(4);
			}
			else if (c.kind == "EDITTEXT" || c.kind == "COMBOBOX" || c.kind == "LISTBOX" || c.kind == "SCROLLBAR")
			{
				if (a.size() < 5)
					return;
				c.idName = a[0];
				rect(1);
				c.style = a.size() > 5 ? a[5] : "";
			}
			else if (c.kind == "ICON")
				return;
			else
			{
				if (a.size() < 6)
					return;
				c.text = unquote(a[0]);
				c.idName = a[1];
				rect(2);
				c.style = a.size() > 6 ? a[6] : "";
			}
			dlg.controls.push_back(c);
		};

		for (++i; i < lines.size(); ++i)
		{
			std::string t = trim(lines[i]);
			if (t.empty() || t[0] == '#' || t.rfind("//", 0) == 0)
				continue;
			if (t == "END" || t == "}")
				break;
			static const char* keywords[] = {"CONTROL", "LTEXT", "RTEXT", "CTEXT", "EDITTEXT", "GROUPBOX", "PUSHBUTTON",
			                                 "DEFPUSHBUTTON", "COMBOBOX", "LISTBOX", "CHECKBOX", "AUTOCHECKBOX", "RADIOBUTTON",
			                                 "AUTORADIOBUTTON", "ICON", "SCROLLBAR", "STATE3", "AUTO3STATE", "PUSHBOX"};
			std::string first = t.substr(0, t.find_first_of(" \t"));
			bool isNew = false;
			for (const char* k : keywords)
				if (first == k)
					isNew = true;
			if (isNew)
				flush();
			stmt += " " + t;
		}
		flush();
		return true;
	}

	bool hasStyle(const std::string& style, const char* flag)
	{
		// "NOT WS_VISIBLE" negates.
		size_t p = style.find(flag);
		while (p != std::string::npos)
		{
			size_t end = p + strlen(flag);
			bool wordEnd = end >= style.size() || !(isalnum((unsigned char)style[end]) || style[end] == '_');
			bool wordStart = p == 0 || !(isalnum((unsigned char)style[p - 1]) || style[p - 1] == '_');
			if (wordEnd && wordStart)
			{
				std::string before = trim(style.substr(0, p));
				return !(before.size() >= 3 && before.compare(before.size() - 3, 3, "NOT") == 0);
			}
			p = style.find(flag, p + 1);
		}
		return false;
	}

	bool hasNotStyle(const std::string& style, const char* flag)
	{
		std::string needle = std::string("NOT ") + flag;
		return style.find(needle) != std::string::npos;
	}

	NSString* stripMnemonic(const std::string& s)
	{
		NSString* label = [NSString stringWithUTF8String: s.c_str()] ?: @"";
		NSMutableString* out = [NSMutableString string];
		for (NSUInteger i = 0; i < label.length; ++i)
		{
			unichar c = [label characterAtIndex: i];
			if (c == '&')
			{
				if (i + 1 < label.length && [label characterAtIndex: i + 1] == '&')
				{
					[out appendString: @"&"];
					++i;
				}
				continue;
			}
			[out appendFormat: @"%C", c];
		}
		return out;
	}
}

@interface NppRcFlippedView : NSView
@end

// Data source for LISTBOX / SysListView32 tables.
@interface NppRcTableSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) NSArray<NSString*>* items;
@property (nonatomic, weak) id owner;
@end

@implementation NppRcTableSource
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _items.count; }
- (id)tableView:(NSTableView*)tv objectValueForTableColumn:(NSTableColumn*)col row:(NSInteger)row { return _items[row]; }
- (void)tableViewSelectionDidChange:(NSNotification*)n
{
	NSTableView* tv = n.object;
	[_owner performSelector: @selector(controlAction:) withObject: tv];
}
@end

@implementation NppRcFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface NppRcDialog () <NSTextFieldDelegate, NSWindowDelegate>
@end

@implementation NppRcDialog
{
	NSMutableDictionary<NSNumber*, NSView*>* _items;
	NSMutableDictionary<NSNumber*, NSNumber*>* _radioGroups;
	NSString* _caption;
	BOOL _modal;
	NSMutableDictionary<NSNumber*, NppRcTableSource*>* _tableSources;
}

+ (int)symbolValue:(NSString*)name
{
	return (int)resolve(name.UTF8String, 0);
}

- (int)idOf:(NSString*)symbol
{
	return [NppRcDialog symbolValue: symbol];
}

- (NSString*)caption
{
	return _caption;
}

- (instancetype)initWithRC:(NSString*)rcFile dialog:(NSString*)dialog
{
	NSPanel* panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 200, 100)
	                                            styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
	                                              backing: NSBackingStoreBuffered
	                                                defer: YES];
	if ((self = [super initWithWindow: panel]))
	{
		_items = [NSMutableDictionary dictionary];
		_radioGroups = [NSMutableDictionary dictionary];
		NSView* v = [NppRcDialog viewFromRC: rcFile dialog: dialog owner: self];
		panel.title = _caption ?: @"";
		[panel setContentSize: v.frame.size];
		panel.contentView = v;
		panel.delegate = self;
		panel.hidesOnDeactivate = NO;   // Win32 owned dialogs stay up when the app loses focus
		[panel center];
	}
	return self;
}

+ (NSView*)viewFromRC:(NSString*)rcFile dialog:(NSString*)dialog owner:(NppRcDialog*)owner
{
	RcDialog dlg;
	if (!parseDialog(rcFile, dialog, dlg))
		return [[NSView alloc] initWithFrame: NSMakeRect(0, 0, 200, 50)];
	if (!owner->_items)
	{
		owner->_items = [NSMutableDictionary dictionary];
		owner->_radioGroups = [NSMutableDictionary dictionary];
	}
	owner->_caption = [NSString stringWithUTF8String: dlg.caption.c_str()];

	NppRcFlippedView* root = [[NppRcFlippedView alloc] initWithFrame: NSMakeRect(0, 0, dlg.w * kDluX, dlg.h * kDluY)];
	NSFont* font = [NSFont systemFontOfSize: 12];
	int group = 0;

	for (const RcControl& c : dlg.controls)
	{
		int cid = (int)resolve(c.idName, 0);
		NSRect r = NSMakeRect(c.x * kDluX, c.y * kDluY, c.w * kDluX, c.h * kDluY);
		std::string kind = c.kind;
		std::string cls = c.cls;
		const std::string& st = c.style;
		if (hasStyle(st, "WS_GROUP"))
			++group;

		NSView* view = nil;
		NSString* text = stripMnemonic(c.text);

		auto makeButton = [&](NSButtonType type) {
			NSButton* b = [[NSButton alloc] initWithFrame: r];
			[b setButtonType: type];
			b.title = text;
			b.font = font;
			b.target = owner;
			b.action = @selector(controlAction:);
			if (type == NSButtonTypeMomentaryPushIn)
			{
				b.bezelStyle = NSBezelStyleRounded;
				// Rounded push buttons need extra height on macOS.
				NSRect f = b.frame;
				f.origin.y -= 3;
				f.size.height = MAX(f.size.height + 6, 28);
				f.origin.x -= 4;
				f.size.width += 8;
				b.frame = f;
			}
			return b;
		};

		if (kind == "CONTROL")
		{
			if (cls == "Button")
			{
				if (hasStyle(st, "BS_AUTORADIOBUTTON") || hasStyle(st, "BS_RADIOBUTTON"))
					kind = "RADIO";
				else if (hasStyle(st, "BS_AUTOCHECKBOX") || hasStyle(st, "BS_CHECKBOX") || hasStyle(st, "BS_AUTO3STATE") || hasStyle(st, "BS_3STATE"))
					kind = "CHECK";
				else if (hasStyle(st, "BS_GROUPBOX"))
					kind = "GROUPBOX";
				else
					kind = hasStyle(st, "BS_DEFPUSHBUTTON") ? "DEFPUSHBUTTON" : "PUSHBUTTON";
			}
			else if (cls == "Static")
				kind = hasStyle(st, "SS_ETCHEDHORZ") || hasStyle(st, "SS_ETCHEDFRAME") ? "SEPARATOR" : hasStyle(st, "SS_RIGHT") ? "RTEXT" : hasStyle(st, "SS_CENTER") ? "CTEXT" : "LTEXT";
			else if (cls == "msctls_trackbar32")
				kind = "SLIDER";
			else if (cls == "msctls_updown32")
				kind = "UPDOWN";
			else if (cls == "SysListView32")
				kind = "LISTVIEW";
			else if (cls == "SysTabControl32")
				kind = "TABS";
			else if (cls == "Edit")
				kind = "EDITTEXT";
			else if (cls == "ComboBox")
				kind = "COMBOBOX";
		}
		else if (kind == "AUTOCHECKBOX" || kind == "CHECKBOX" || kind == "AUTO3STATE" || kind == "STATE3")
			kind = "CHECK";
		else if (kind == "AUTORADIOBUTTON" || kind == "RADIOBUTTON")
			kind = "RADIO";

		if (kind == "LTEXT" || kind == "RTEXT" || kind == "CTEXT")
		{
			NSTextField* l = [NSTextField wrappingLabelWithString: text];
			l.frame = NSOffsetRect(r, 0, 1);
			l.font = font;
			l.alignment = kind == "RTEXT" ? NSTextAlignmentRight : kind == "CTEXT" ? NSTextAlignmentCenter : NSTextAlignmentLeft;
			l.selectable = NO;
			view = l;
		}
		else if (kind == "SEPARATOR")
		{
			NSBox* b = [[NSBox alloc] initWithFrame: r];
			b.boxType = NSBoxSeparator;
			view = b;
		}
		else if (kind == "GROUPBOX")
		{
			NSBox* b = [[NSBox alloc] initWithFrame: NSInsetRect(r, -2, -2)];
			b.title = text;
			b.titleFont = [NSFont systemFontOfSize: 11];
			view = b;
		}
		else if (kind == "PUSHBUTTON" || kind == "DEFPUSHBUTTON")
		{
			NSButton* b = makeButton(NSButtonTypeMomentaryPushIn);
			if (kind == "DEFPUSHBUTTON")
				b.keyEquivalent = @"\r";
			if (cid == IDCANCEL)
				b.keyEquivalent = @"\e";
			view = b;
		}
		else if (kind == "CHECK")
			view = makeButton(NSButtonTypeSwitch);
		else if (kind == "RADIO")
		{
			// AppKit makes radios sharing a superview and action mutually exclusive,
			// so each Win32 radio group (WS_GROUP) gets its own action selector.
			NSButton* b = makeButton(NSButtonTypeRadio);
			SEL groupSel = NSSelectorFromString([NSString stringWithFormat: @"radioGroup%d:", group]);
			if (![owner respondsToSelector: groupSel])
				class_addMethod(NppRcDialog.class, groupSel, class_getMethodImplementation(NppRcDialog.class, @selector(controlAction:)), "v@:@");
			b.action = groupSel;
			view = b;
			owner->_radioGroups[@(cid)] = @(group);
		}
		else if (kind == "EDITTEXT")
		{
			if (hasStyle(st, "ES_MULTILINE"))
			{
				NSScrollView* sv = [[NSScrollView alloc] initWithFrame: r];
				sv.hasVerticalScroller = YES;
				sv.borderType = NSBezelBorder;
				NSTextView* tv = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, r.size.width, r.size.height)];
				tv.font = font;
				tv.editable = !hasStyle(st, "ES_READONLY");
				tv.autoresizingMask = NSViewWidthSizable;
				sv.documentView = tv;
				view = sv;
			}
			else
			{
				NSRect er = r;
				er.size.height = MAX(er.size.height, 22);
				if (c.w < 40)
				{
					// Short numeric fields: the macOS font is wider than 8pt MS Shell Dlg.
					er.origin.x -= 6;
					er.size.width += 12;
				}
				NSTextField* f = hasStyle(st, "ES_PASSWORD") ? [[NSSecureTextField alloc] initWithFrame: er] : [[NSTextField alloc] initWithFrame: er];
				f.font = font;
				f.editable = !hasStyle(st, "ES_READONLY");
				f.alignment = hasStyle(st, "ES_CENTER") ? NSTextAlignmentCenter : hasStyle(st, "ES_RIGHT") ? NSTextAlignmentRight : NSTextAlignmentLeft;
				f.delegate = owner;
				f.tag = cid;
				f.target = owner;
				f.action = @selector(controlAction:);
				if (hasStyle(st, "ES_NUMBER"))
				{
					NSNumberFormatter* nf = [[NSNumberFormatter alloc] init];
					nf.allowsFloats = NO;
					nf.minimum = @0;
					f.formatter = nf;
				}
				view = f;
			}
		}
		else if (kind == "COMBOBOX")
		{
			NSRect cr = r;
			cr.size.height = 26;
			if (hasStyle(st, "CBS_DROPDOWNLIST"))
			{
				NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame: cr pullsDown: NO];
				p.font = font;
				p.target = owner;
				p.action = @selector(controlAction:);
				view = p;
			}
			else
			{
				NSComboBox* cb = [[NSComboBox alloc] initWithFrame: cr];
				cb.font = font;
				cb.completes = NO;
				cb.target = owner;
				cb.action = @selector(controlAction:);
				cb.delegate = (id<NSComboBoxDelegate>)owner;
				view = cb;
			}
		}
		else if (kind == "LISTBOX" || kind == "LISTVIEW")
		{
			NSScrollView* sv = [[NSScrollView alloc] initWithFrame: r];
			sv.hasVerticalScroller = YES;
			sv.borderType = NSBezelBorder;
			NSTableView* tv = [[NSTableView alloc] initWithFrame: sv.bounds];
			NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier: @"0"];
			col.width = r.size.width - 20;
			[tv addTableColumn: col];
			tv.headerView = nil;
			tv.tag = cid;
			tv.rowHeight = 17;
			if (!owner->_tableSources)
				owner->_tableSources = [NSMutableDictionary dictionary];
			NppRcTableSource* src = [[NppRcTableSource alloc] init];
			src.owner = owner;
			src.items = @[];
			owner->_tableSources[@(cid)] = src;
			tv.dataSource = src;
			tv.delegate = src;
			sv.documentView = tv;
			view = sv;
		}
		else if (kind == "SLIDER")
		{
			NSSlider* s = [[NSSlider alloc] initWithFrame: r];
			s.target = owner;
			s.action = @selector(controlAction:);
			view = s;
		}
		else if (kind == "UPDOWN")
		{
			NSStepper* s = [[NSStepper alloc] initWithFrame: r];
			s.target = owner;
			s.action = @selector(controlAction:);
			view = s;
		}
		else if (kind == "TABS")
		{
			NSSegmentedControl* s = [[NSSegmentedControl alloc] initWithFrame: NSMakeRect(r.origin.x, r.origin.y, r.size.width, 24)];
			s.target = owner;
			s.action = @selector(controlAction:);
			view = s;
		}

		if (!view)
			continue;
		if ([view isKindOfClass: NSControl.class])
		{
			((NSControl*)view).tag = cid;
			if (hasStyle(st, "WS_DISABLED"))
				((NSControl*)view).enabled = NO;
		}
		if (hasNotStyle(st, "WS_VISIBLE"))
			view.hidden = YES;
		[root addSubview: view];
		if (cid > 0 && !owner->_items[@(cid)])
			owner->_items[@(cid)] = view;
	}
	return root;
}

#pragma mark - Control access

- (NSView*)item:(int)ctrlId
{
	return _items[@(ctrlId)];
}

- (BOOL)isChecked:(int)ctrlId
{
	NSButton* b = (NSButton*)[self item: ctrlId];
	return [b isKindOfClass: NSButton.class] && b.state == NSControlStateValueOn;
}

- (void)setChecked:(int)ctrlId value:(BOOL)on
{
	NSButton* b = (NSButton*)[self item: ctrlId];
	if (![b isKindOfClass: NSButton.class])
		return;
	b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
	if (on)
		[self uncheckGroupOf: b];
}

- (NSString*)text:(int)ctrlId
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSPopUpButton.class])
		return ((NSPopUpButton*)v).titleOfSelectedItem ?: @"";
	if ([v isKindOfClass: NSButton.class])
		return ((NSButton*)v).title;
	if ([v isKindOfClass: NSControl.class])
		return ((NSControl*)v).stringValue;
	if ([v isKindOfClass: NSScrollView.class] && [((NSScrollView*)v).documentView isKindOfClass: NSTextView.class])
		return ((NSTextView*)((NSScrollView*)v).documentView).string;
	return @"";
}

- (void)setText:(int)ctrlId value:(NSString*)text
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSButton.class] && ![v isKindOfClass: NSPopUpButton.class])
		((NSButton*)v).title = text ?: @"";
	else if ([v isKindOfClass: NSControl.class])
		((NSControl*)v).stringValue = text ?: @"";
	else if ([v isKindOfClass: NSScrollView.class] && [((NSScrollView*)v).documentView isKindOfClass: NSTextView.class])
		((NSTextView*)((NSScrollView*)v).documentView).string = text ?: @"";
}

- (void)enable:(int)ctrlId value:(BOOL)on
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSControl.class])
		((NSControl*)v).enabled = on;
}

- (void)show:(int)ctrlId value:(BOOL)on
{
	[self item: ctrlId].hidden = !on;
}

#pragma mark - Lists

- (NSTableView*)tableFor:(int)ctrlId
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSScrollView.class] && [((NSScrollView*)v).documentView isKindOfClass: NSTableView.class])
		return ((NSScrollView*)v).documentView;
	return nil;
}

- (void)setItems:(NSArray<NSString*>*)items forList:(int)ctrlId
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSPopUpButton.class])
	{
		[(NSPopUpButton*)v removeAllItems];
		for (NSString* s in items)
		{
			// addItemWithTitle: drops duplicate titles; menus keep them.
			[((NSPopUpButton*)v).menu addItemWithTitle: s action: nil keyEquivalent: @""];
		}
	}
	else if ([v isKindOfClass: NSComboBox.class])
	{
		[(NSComboBox*)v removeAllItems];
		[(NSComboBox*)v addItemsWithObjectValues: items];
	}
	else if (NSTableView* tv = [self tableFor: ctrlId])
	{
		_tableSources[@(ctrlId)].items = items;
		[tv reloadData];
	}
}

- (NSInteger)selectedIndex:(int)ctrlId
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSPopUpButton.class])
		return ((NSPopUpButton*)v).indexOfSelectedItem;
	if ([v isKindOfClass: NSComboBox.class])
		return ((NSComboBox*)v).indexOfSelectedItem;
	if (NSTableView* tv = [self tableFor: ctrlId])
		return tv.selectedRow;
	return -1;
}

- (void)select:(NSInteger)index inList:(int)ctrlId
{
	NSView* v = [self item: ctrlId];
	if ([v isKindOfClass: NSPopUpButton.class])
		[(NSPopUpButton*)v selectItemAtIndex: index];
	else if ([v isKindOfClass: NSComboBox.class])
		[(NSComboBox*)v selectItemAtIndex: index];
	else if (NSTableView* tv = [self tableFor: ctrlId])
	{
		[tv selectRowIndexes: [NSIndexSet indexSetWithIndex: index] byExtendingSelection: NO];
		[tv scrollRowToVisible: index];
	}
}

#pragma mark - Commands

- (void)uncheckGroupOf:(NSButton*)b
{
	NSNumber* group = _radioGroups[@(b.tag)];
	if (!group)
		return;
	for (NSNumber* other in _radioGroups)
		if ([_radioGroups[other] isEqual: group] && other.intValue != b.tag)
			((NSButton*)_items[other]).state = NSControlStateValueOff;
}

- (void)controlAction:(id)sender
{
	int cid = (int)[sender tag];
	if ([sender isKindOfClass: NSButton.class] && _radioGroups[@(cid)])
		[self uncheckGroupOf: sender];
	[self dispatch: cid];
}

- (void)dispatch:(int)cid
{
	BOOL handled = _onCommand ? _onCommand(self, cid) : NO;
	if (!handled && (cid == IDOK || cid == IDCANCEL))
		[self endWith: cid];
}

- (void)controlTextDidChange:(NSNotification*)n
{
	_lastNotification = 0x0300; // EN_CHANGE
	[self dispatch: (int)[n.object tag]];
	_lastNotification = 0;
}

- (void)cancelOperation:(id)sender
{
	[self dispatch: IDCANCEL];
}

- (BOOL)windowShouldClose:(NSWindow*)sender
{
	[self dispatch: IDCANCEL];
	return NO;
}

- (void)showModeless
{
	_modal = NO;
	[self showWindow: nil];
}

- (NSModalResponse)runModal
{
	_modal = YES;
	return [NSApp runModalForWindow: self.window];
}

- (void)endWith:(int)ctrlId
{
	if (_modal)
	{
		_modal = NO;
		[NSApp stopModalWithCode: ctrlId];
	}
	[self.window orderOut: nil];
}

@end
