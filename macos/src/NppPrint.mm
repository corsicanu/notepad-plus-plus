// File > Print / Print Now: port of Printer (Printer.cpp). Pages are laid out
// by Scintilla's SCI_FORMATRANGEFULL into the print context, with
// Notepad++'s header / footer, margins, colour mode, line numbers and
// form-feed page breaks from Settings > Preferences > Print.

#import "NppMainWindowInternal.h"

#include "LangManager.h"
#include "NppSettings.h"
#include "NppShortcuts.h"
#include "NppUpstream.h"

#include <unordered_map>
#include <vector>

typedef void (^NppCommandHandler)(NppMainWindow* w);

@interface NppMainWindow (PrintHost)
- (std::string)runVariable:(const std::string&)name;
@end

namespace
{
	sptr_t sci(ScintillaView* v, unsigned int m, uptr_t w = 0, sptr_t l = 0)
	{
		return [ScintillaView directCall: v message: m wParam: w lParam: l];
	}

	NSString* ns(const std::string& s)
	{
		return [NSString stringWithUTF8String: s.c_str()] ?: @"";
	}

	NSFont* headerFont(const std::string& name, int size, int style)
	{
		CGFloat pt = size ? size : 9;
		NSFont* f = [NSFont fontWithName: name.empty() ? @"Arial" : ns(name) size: pt] ?: [NSFont systemFontOfSize: pt];
		NSFontTraitMask traits = 0;
		if (style & FONTSTYLE_BOLD)
			traits |= NSBoldFontMask;
		if (style & FONTSTYLE_ITALIC)
			traits |= NSItalicFontMask;
		return traits ? [NSFontManager.sharedFontManager convertFont: f toHaveTrait: traits] : f;
	}
}

@interface NppPrintView : NSView
- (instancetype)initWithWindow:(NppMainWindow*)window;
@end

@implementation NppPrintView
{
	__weak NppMainWindow* _window;
	ScintillaView* _view;              // off-screen view on the document
	NSString* _header[3];
	NSString* _footer[3];
	NSFont* _headerFont;
	NSFont* _footerFont;
	NSSize _paper;
	NSRect _body;                      // text area of a page, page-relative
	CGFloat _headerHeight, _footerHeight;
	std::vector<std::pair<sptr_t, sptr_t>> _pages;   // character range of each page
	CGContextRef _measure;
}

- (instancetype)initWithWindow:(NppMainWindow*)window
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, 100, 100)]))
	{
		_window = window;
		const NppSettings& s = NppSettings::instance();
		ScintillaView* e = window.editor;

		// Same document, language, margins as the editor (Printer prints the edit view).
		_view = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 800, 600)];
		sci(_view, SCI_SETDOCPOINTER, 0, sci(e, SCI_GETDOCPOINTER));
		sci(_view, SCI_SETCODEPAGE, SC_CP_UTF8);
		[window.currentBuffer applyLanguageTo: _view];
		for (int m = 0; m < 5; ++m)
		{
			sci(_view, SCI_SETMARGINTYPEN, m, sci(e, SCI_GETMARGINTYPEN, m));
			sci(_view, SCI_SETMARGINWIDTHN, m, sci(e, SCI_GETMARGINWIDTHN, m));
		}
		if (!s._printLineNumber)
			sci(_view, SCI_SETMARGINWIDTHN, MARGIN_LINENUMBER, 0);
		sci(_view, SCI_SETWRAPMODE, SC_WRAP_WORD);
		sci(_view, SCI_SETPRINTWRAPMODE, SC_WRAP_WORD);
		sci(_view, SCI_SETPRINTCOLOURMODE, s._printOption);

		// SHORT_DATE / LONG_DATE / TIME, then the $(...) variables (expandNppEnvironmentStrs).
		NSDate* now = [NSDate date];
		NSString* shortDate = [NSDateFormatter localizedStringFromDate: now dateStyle: NSDateFormatterShortStyle timeStyle: NSDateFormatterNoStyle];
		NSString* longDate = [NSDateFormatter localizedStringFromDate: now dateStyle: NSDateFormatterFullStyle timeStyle: NSDateFormatterNoStyle];
		NSString* time = [NSDateFormatter localizedStringFromDate: now dateStyle: NSDateFormatterNoStyle timeStyle: NSDateFormatterShortStyle];
		__weak NppMainWindow* w = window;
		auto expand = ^NSString*(const std::string& part) {
			if (part.empty())
				return @"";
			NSString* t = ns(part);
			t = [t stringByReplacingOccurrencesOfString: @"$(SHORT_DATE)" withString: shortDate];
			t = [t stringByReplacingOccurrencesOfString: @"$(LONG_DATE)" withString: longDate];
			t = [t stringByReplacingOccurrencesOfString: @"$(TIME)" withString: time];
			return ns(nppExpandVariables(t.UTF8String, [w](const std::string& name) { return [w runVariable: name]; }));
		};
		_header[0] = expand(s._printHeaderLeft);
		_header[1] = expand(s._printHeaderMiddle);
		_header[2] = expand(s._printHeaderRight);
		_footer[0] = expand(s._printFooterLeft);
		_footer[1] = expand(s._printFooterMiddle);
		_footer[2] = expand(s._printFooterRight);
		_headerFont = headerFont(s._printHeaderFontName, s._printHeaderFontSize, s._printHeaderFontStyle);
		_footerFont = headerFont(s._printFooterFontName, s._printFooterFontSize, s._printFooterFontStyle);

		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		_measure = CGBitmapContextCreate(nullptr, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
		CGColorSpaceRelease(cs);
	}
	return self;
}

- (void)dealloc
{
	sci(_view, SCI_FORMATRANGEFULL, 0, 0);
	sci(_view, SCI_SETDOCPOINTER, 0, 0);
	CGContextRelease(_measure);
}

- (BOOL)isFlipped
{
	return YES;
}

- (BOOL)hasHeader { return _header[0].length || _header[1].length || _header[2].length; }
- (BOOL)hasFooter { return _footer[0].length || _footer[1].length || _footer[2].length; }

// Printer::doPrint's page geometry: user margins (mm) but at least the
// printer's unprintable area, plus 1.5 lines, plus header / footer.
- (void)layoutForPrintInfo:(NSPrintInfo*)info
{
	const NppSettings& s = NppSettings::instance();
	_paper = info.paperSize;
	NSRect imageable = info.imageablePageBounds;
	auto mm = [](int v) { return v * 72.0 / 25.4; };
	CGFloat left = std::max<CGFloat>(imageable.origin.x, mm(s._printMargeLeft));
	CGFloat right = std::max<CGFloat>(_paper.width - NSMaxX(imageable), mm(s._printMargeRight));
	CGFloat top = std::max<CGFloat>(_paper.height - NSMaxY(imageable), mm(s._printMargeTop));
	CGFloat bottom = std::max<CGFloat>(imageable.origin.y, mm(s._printMargeBottom));

	CGFloat printMarge = (_footerFont.ascender - _footerFont.descender + _footerFont.leading) * 1.5;
	_headerHeight = _headerFont.ascender - _headerFont.descender + _headerFont.leading;
	_footerHeight = _footerFont.ascender - _footerFont.descender + _footerFont.leading;

	_body = NSMakeRect(left + printMarge, top + printMarge,
	                   _paper.width - left - right - 2 * printMarge, _paper.height - top - bottom - 2 * printMarge);
	if ([self hasHeader])
	{
		_body.origin.y += _headerHeight * 1.5;
		_body.size.height -= _headerHeight * 1.5;
	}
	if ([self hasFooter])
		_body.size.height -= _footerHeight * 1.5;
}

- (Sci_RangeToFormatFull)rangeFor:(NSRect)page from:(sptr_t)start to:(sptr_t)end hdc:(CGContextRef)hdc
{
	Sci_RangeToFormatFull fr{};
	fr.hdc = hdc;
	fr.hdcTarget = hdc;
	fr.rc = {static_cast<int>(page.origin.x + _body.origin.x), static_cast<int>(page.origin.y + _body.origin.y),
	         static_cast<int>(page.origin.x + NSMaxX(_body)), static_cast<int>(page.origin.y + NSMaxY(_body))};
	fr.rcPage = {static_cast<int>(page.origin.x), static_cast<int>(page.origin.y),
	             static_cast<int>(page.origin.x + _paper.width), static_cast<int>(page.origin.y + _paper.height)};
	fr.chrg.cpMin = start;
	fr.chrg.cpMax = end;
	return fr;
}

// Splits the document into pages (FORMATRANGE without drawing), honouring form feeds.
- (void)paginate
{
	_pages.clear();
	const NppSettings& s = NppSettings::instance();
	sptr_t length = sci(_view, SCI_GETLENGTH);
	sptr_t printed = 0;
	CGContextSaveGState(_measure);
	while (printed < length)
	{
		Sci_RangeToFormatFull fr = [self rangeFor: NSMakeRect(0, 0, _paper.width, _paper.height) from: printed to: length hdc: _measure];
		sptr_t formFeed = -1;
		if (s._printFormFeedPageBreak)
		{
			Sci_TextToFindFull ttf{};
			ttf.chrg = fr.chrg;
			ttf.lpstrText = "\f";
			formFeed = sci(_view, SCI_FINDTEXTFULL, SCFIND_NONE, reinterpret_cast<sptr_t>(&ttf));
			if (formFeed > 0)
				fr.chrg.cpMax = formFeed - 1;
			else if (formFeed == 0)
				fr.chrg.cpMax = 0;
		}
		sptr_t next = sci(_view, SCI_FORMATRANGEFULL, 0, reinterpret_cast<sptr_t>(&fr));
		if (formFeed != -1 && next <= formFeed)
			next = formFeed + 1;
		if (next <= printed)   // nothing fits: stop instead of looping
			break;
		_pages.push_back({printed, fr.chrg.cpMax < length ? std::min(next, length) : length});
		printed = next;
	}
	CGContextRestoreGState(_measure);
	if (_pages.empty())
		_pages.push_back({0, 0});
	self.frame = NSMakeRect(0, 0, _paper.width, _paper.height * _pages.size());
}

#pragma mark NSView printing

- (BOOL)knowsPageRange:(NSRangePointer)range
{
	[self layoutForPrintInfo: NSPrintOperation.currentOperation.printInfo];
	[self paginate];
	*range = NSMakeRange(1, _pages.size());
	return YES;
}

- (NSRect)rectForPage:(NSInteger)page
{
	return NSMakeRect(0, (page - 1) * _paper.height, _paper.width, _paper.height);
}

- (void)drawRect:(NSRect)dirty
{
	if (NSPrintOperation.currentOperation && !_pages.empty())
	{
		NSInteger page = std::max<NSInteger>(1, NSPrintOperation.currentOperation.currentPage);
		if (page > (NSInteger)_pages.size())
			return;
		NSRect pageRect = [self rectForPage: page];
		CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

		Sci_RangeToFormatFull fr = [self rangeFor: pageRect from: _pages[page - 1].first to: _pages[page - 1].second hdc: ctx];
		CGContextSaveGState(ctx);
		sci(_view, SCI_FORMATRANGEFULL, 1, reinterpret_cast<sptr_t>(&fr));
		CGContextRestoreGState(ctx);

		NSString* pageNum = [NSString stringWithFormat: @"%ld", (long)page];
		NSRect body = NSOffsetRect(_body, pageRect.origin.x, pageRect.origin.y);
		if ([self hasHeader])
			[self drawParts: _header font: _headerFont page: pageNum
			       baseline: body.origin.y - _headerHeight / 2 rule: body.origin.y - _headerHeight / 4 body: body];
		if ([self hasFooter])
			[self drawParts: _footer font: _footerFont page: pageNum
			       baseline: NSMaxY(body) + _footerHeight / 2 + _footerHeight rule: NSMaxY(body) + _footerHeight / 4 body: body];
	}
}

// Left / middle / right parts and the separator line, $(CURRENT_PRINTING_PAGE) filled in.
- (void)drawParts:(NSString* __strong*)parts font:(NSFont*)font page:(NSString*)page baseline:(CGFloat)y rule:(CGFloat)ruleY body:(NSRect)body
{
	NSDictionary* attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor};
	for (int i = 0; i < 3; ++i)
	{
		NSString* t = [parts[i] stringByReplacingOccurrencesOfString: @"$(CURRENT_PRINTING_PAGE)" withString: page];
		if (!t.length)
			continue;
		NSSize size = [t sizeWithAttributes: attrs];
		CGFloat x = i == 0 ? body.origin.x + 5 : i == 1 ? NSMidX(body) - size.width / 2 : NSMaxX(body) - size.width;
		[t drawAtPoint: NSMakePoint(x, y - size.height) withAttributes: attrs];
	}
	NSBezierPath* line = [NSBezierPath bezierPath];
	[line moveToPoint: NSMakePoint(body.origin.x, ruleY)];
	[line lineToPoint: NSMakePoint(NSMaxX(body), ruleY)];
	line.lineWidth = 0.5;
	[NSColor.blackColor setStroke];
	[line stroke];
}

@end

@implementation NppMainWindow (Print)

+ (void)registerPrintCommands:(std::unordered_map<int, NppCommandHandler>&)t
{
	// Print shows the print panel; Print Now prints to the default printer (PD_RETURNDEFAULT).
	t[IDM_FILE_PRINT] = ^(NppMainWindow* w) { [w printDocument: YES toPDF: nil]; };
	t[IDM_FILE_PRINTNOW] = ^(NppMainWindow* w) { [w printDocument: NO toPDF: nil]; };
}

- (void)printDocument:(BOOL)showPanel toPDF:(NSString*)pdfPath
{
	NppPrintView* v = [[NppPrintView alloc] initWithWindow: self];
	NSPrintInfo* info = [NSPrintInfo.sharedPrintInfo copy];
	info.topMargin = info.bottomMargin = info.leftMargin = info.rightMargin = 0;
	info.horizontalPagination = NSPrintingPaginationModeClip;
	info.verticalPagination = NSPrintingPaginationModeClip;
	if (pdfPath)
	{
		info.jobDisposition = NSPrintSaveJob;
		info.dictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath: pdfPath];
	}
	NSPrintOperation* op = [NSPrintOperation printOperationWithView: v printInfo: info];
	op.jobTitle = self.currentBuffer.displayName;
	op.showsPrintPanel = showPanel;
	op.showsProgressPanel = !pdfPath;
	if (pdfPath)
		[op runOperation];
	else
		[op runOperationModalForWindow: self.window delegate: nil didRunSelector: nil contextInfo: nullptr];
}

@end
