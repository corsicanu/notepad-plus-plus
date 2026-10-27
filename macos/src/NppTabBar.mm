#import "NppTabBar.h"

#include <algorithm>
#include <vector>

namespace
{
	const CGFloat kTabHeight = 26;
	const CGFloat kTabMinWidth = 60;
	const CGFloat kTabMaxWidth = 220;
	const CGFloat kIconSize = 12;
	const CGFloat kCloseSize = 12;
	const CGFloat kPad = 6;

	NSColor* activeStripe() { return [NSColor colorWithSRGBRed: 0xFA / 255.0 green: 0xAA / 255.0 blue: 0x3C / 255.0 alpha: 1]; }
}

@implementation NppTabBar
{
	NSArray<NSString*>* _titles;
	NSArray<NSNumber*>* _states;
	NSArray<NSString*>* _tooltips;
	std::vector<NSRect> _rects;
	NSInteger _hoverClose;
	NSInteger _dragIndex;
	NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super initWithFrame: frame]))
	{
		_hoverClose = -1;
		_dragIndex = -1;
		_titles = @[];
	}
	return self;
}

- (BOOL)isFlipped
{
	return YES;
}

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(NSViewNoIntrinsicMetric, kTabHeight);
}

- (NSDictionary*)titleAttributes:(BOOL)active
{
	NSFont* font = active ? [NSFont boldSystemFontOfSize: 11.5] : [NSFont systemFontOfSize: 11.5];
	return @{NSFontAttributeName: font, NSForegroundColorAttributeName: active ? NSColor.labelColor : NSColor.secondaryLabelColor};
}

- (void)setTabs:(NSArray<NSString*>*)titles states:(NSArray<NSNumber*>*)states tooltips:(NSArray<NSString*>*)tooltips
{
	_titles = [titles copy];
	_states = [states copy];
	_tooltips = [tooltips copy];
	[self layoutTabs];
	[self setNeedsDisplay: YES];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex
{
	_selectedIndex = selectedIndex;
	[self layoutTabs];
	[self setNeedsDisplay: YES];
}

- (void)layoutTabs
{
	_rects.clear();
	[self removeAllToolTips];
	CGFloat x = 0;
	for (NSUInteger i = 0; i < _titles.count; ++i)
	{
		NSSize ts = [_titles[i] sizeWithAttributes: [self titleAttributes: YES]];
		CGFloat w = kPad + kIconSize + kPad + ts.width + kPad + kCloseSize + kPad;
		w = std::min(std::max(w, kTabMinWidth), kTabMaxWidth);
		NSRect r = NSMakeRect(x, 0, w, kTabHeight);
		_rects.push_back(r);
		if (i < _tooltips.count)
			[self addToolTipRect: r owner: _tooltips[i] userData: nil];
		x += w;
	}
}

- (NSRect)closeRectForTab:(NSInteger)i
{
	NSRect r = _rects[i];
	return NSMakeRect(NSMaxX(r) - kPad - kCloseSize, (kTabHeight - kCloseSize) / 2 + 1, kCloseSize, kCloseSize);
}

- (void)drawStateIcon:(NppTabState)state inRect:(NSRect)r
{
	// Small floppy, like Notepad++'s saved (blue) / unsaved (red) / read-only (grey) tab icons.
	NSColor* body = state == NppTabUnsaved ? [NSColor colorWithSRGBRed: 0.85 green: 0.15 blue: 0.15 alpha: 1]
	              : state == NppTabReadOnly ? NSColor.systemGrayColor
	              : [NSColor colorWithSRGBRed: 0.15 green: 0.40 blue: 0.85 alpha: 1];
	[body setFill];
	[[NSBezierPath bezierPathWithRoundedRect: r xRadius: 1.5 yRadius: 1.5] fill];
	[[NSColor colorWithWhite: 1 alpha: 0.9] setFill];
	NSRectFill(NSMakeRect(r.origin.x + 2.5, r.origin.y + 1.5, r.size.width - 5, r.size.height * 0.38));
	NSRectFill(NSMakeRect(r.origin.x + 3.5, NSMaxY(r) - 4, r.size.width - 7, 2.5));
}

- (void)drawRect:(NSRect)dirtyRect
{
	BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames: @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
	NSColor* barBg = dark ? [NSColor colorWithWhite: 0.16 alpha: 1] : [NSColor colorWithWhite: 0.86 alpha: 1];
	NSColor* inactiveBg = dark ? [NSColor colorWithWhite: 0.22 alpha: 1] : [NSColor colorWithWhite: 0.93 alpha: 1];
	NSColor* activeBg = dark ? [NSColor colorWithWhite: 0.12 alpha: 1] : NSColor.whiteColor;
	NSColor* border = dark ? [NSColor colorWithWhite: 0.35 alpha: 1] : [NSColor colorWithWhite: 0.70 alpha: 1];

	[barBg setFill];
	NSRectFill(self.bounds);

	for (NSUInteger i = 0; i < _rects.size(); ++i)
	{
		NSRect r = _rects[i];
		BOOL active = (NSInteger)i == _selectedIndex;
		[(active ? activeBg : inactiveBg) setFill];
		NSRectFill(NSInsetRect(r, 0.5, 0));
		[border setFill];
		NSRectFill(NSMakeRect(NSMaxX(r) - 1, r.origin.y + 3, 1, r.size.height - 3));
		if (active)
		{
			[activeStripe() setFill];
			NSRectFill(NSMakeRect(r.origin.x, 0, r.size.width - 1, 3));
		}

		NppTabState state = i < _states.count ? (NppTabState)_states[i].integerValue : NppTabSaved;
		[self drawStateIcon: state inRect: NSMakeRect(r.origin.x + kPad, (kTabHeight - kIconSize) / 2 + 1, kIconSize, kIconSize)];

		NSDictionary* attrs = [self titleAttributes: active];
		NSRect tr = NSMakeRect(r.origin.x + kPad + kIconSize + kPad, 0, r.size.width - (3 * kPad + kIconSize + kCloseSize + kPad), kTabHeight);
		NSSize ts = [_titles[i] sizeWithAttributes: attrs];
		tr.origin.y = (kTabHeight - ts.height) / 2 + 1;
		tr.size.height = ts.height;
		NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init];
		ps.lineBreakMode = NSLineBreakByTruncatingTail;
		NSMutableDictionary* a = [attrs mutableCopy];
		a[NSParagraphStyleAttributeName] = ps;
		[_titles[i] drawInRect: tr withAttributes: a];

		NSRect cr = [self closeRectForTab: i];
		if ((NSInteger)i == _hoverClose)
		{
			[[NSColor colorWithSRGBRed: 0.85 green: 0.2 blue: 0.2 alpha: 1] setFill];
			[[NSBezierPath bezierPathWithRoundedRect: cr xRadius: 2 yRadius: 2] fill];
		}
		NSBezierPath* x = [NSBezierPath bezierPath];
		NSRect xr = NSInsetRect(cr, 3, 3);
		[x moveToPoint: xr.origin];
		[x lineToPoint: NSMakePoint(NSMaxX(xr), NSMaxY(xr))];
		[x moveToPoint: NSMakePoint(NSMaxX(xr), xr.origin.y)];
		[x lineToPoint: NSMakePoint(xr.origin.x, NSMaxY(xr))];
		x.lineWidth = 1.3;
		[((NSInteger)i == _hoverClose ? NSColor.whiteColor : NSColor.secondaryLabelColor) setStroke];
		[x stroke];
	}

	[border setFill];
	NSRectFill(NSMakeRect(0, kTabHeight - 1, self.bounds.size.width, 1));
}

- (NSInteger)tabAtPoint:(NSPoint)p
{
	for (NSUInteger i = 0; i < _rects.size(); ++i)
		if (NSPointInRect(p, _rects[i]))
			return i;
	return -1;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea: _tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect: self.bounds
	                                         options: NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
	                                           owner: self userInfo: nil];
	[self addTrackingArea: _tracking];
}

- (void)mouseMoved:(NSEvent*)event
{
	NSPoint p = [self convertPoint: event.locationInWindow fromView: nil];
	NSInteger i = [self tabAtPoint: p];
	NSInteger hover = (i >= 0 && NSPointInRect(p, [self closeRectForTab: i])) ? i : -1;
	if (hover != _hoverClose)
	{
		_hoverClose = hover;
		[self setNeedsDisplay: YES];
	}
}

- (void)mouseExited:(NSEvent*)event
{
	_hoverClose = -1;
	[self setNeedsDisplay: YES];
}

- (void)mouseDown:(NSEvent*)event
{
	NSPoint p = [self convertPoint: event.locationInWindow fromView: nil];
	NSInteger i = [self tabAtPoint: p];
	if (i < 0)
	{
		if (event.clickCount == 2)
			[_delegate tabBarDidRequestNewTab: self];
		return;
	}
	if (NSPointInRect(p, [self closeRectForTab: i]))
	{
		[_delegate tabBar: self didRequestCloseTabAtIndex: i];
		return;
	}
	if (i != _selectedIndex)
		[_delegate tabBar: self didSelectTabAtIndex: i];
	_dragIndex = i;
}

- (void)mouseDragged:(NSEvent*)event
{
	if (_dragIndex < 0)
		return;
	NSPoint p = [self convertPoint: event.locationInWindow fromView: nil];
	NSInteger target = [self tabAtPoint: NSMakePoint(p.x, kTabHeight / 2)];
	if (target >= 0 && target != _dragIndex)
	{
		[_delegate tabBar: self didMoveTabFromIndex: _dragIndex toIndex: target];
		_dragIndex = target;
	}
}

- (void)mouseUp:(NSEvent*)event
{
	_dragIndex = -1;
}

- (void)otherMouseUp:(NSEvent*)event
{
	// Middle click closes, as in Notepad++.
	if (event.buttonNumber != 2)
		return;
	NSInteger i = [self tabAtPoint: [self convertPoint: event.locationInWindow fromView: nil]];
	if (i >= 0)
		[_delegate tabBar: self didRequestCloseTabAtIndex: i];
}

@end
