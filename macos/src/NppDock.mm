#import "NppDock.h"

// One side of the window: caption, the selected panel, tabs.
@interface NppDockContainer : NSView
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
- (void)setPanels:(NSArray<id<NppDockPanel>>*)panels selected:(NSInteger)selected;
@end

@implementation NppDockContainer
{
	NSTextField* _caption;
	NSButton* _close;
	NSView* _body;
	NSSegmentedControl* _tabs;
	NSLayoutConstraint* _tabsHeight;
	NSArray<id<NppDockPanel>>* _panels;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super initWithFrame: frame]))
	{
		_caption = [NSTextField labelWithString: @""];
		_caption.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize weight: NSFontWeightSemibold];
		_caption.lineBreakMode = NSLineBreakByTruncatingTail;
		_caption.translatesAutoresizingMaskIntoConstraints = NO;
		[_caption setContentCompressionResistancePriority: 1 forOrientation: NSLayoutConstraintOrientationHorizontal];

		_close = [NSButton buttonWithImage: [NSImage imageWithSystemSymbolName: @"xmark" accessibilityDescription: @"Close"]
		                            target: self action: @selector(closePanel:)];
		_close.bordered = NO;
		_close.translatesAutoresizingMaskIntoConstraints = NO;

		_body = [[NSView alloc] init];
		_body.translatesAutoresizingMaskIntoConstraints = NO;

		_tabs = [NSSegmentedControl segmentedControlWithLabels: @[] trackingMode: NSSegmentSwitchTrackingSelectOne
		                                                target: self action: @selector(tabChanged:)];
		_tabs.segmentStyle = NSSegmentStyleSmallSquare;
		_tabs.controlSize = NSControlSizeSmall;
		_tabs.translatesAutoresizingMaskIntoConstraints = NO;
		_tabsHeight = [_tabs.heightAnchor constraintEqualToConstant: 0];

		for (NSView* v in @[_caption, _close, _body, _tabs])
			[self addSubview: v];
		[NSLayoutConstraint activateConstraints: @[
			[_caption.topAnchor constraintEqualToAnchor: self.topAnchor constant: 4],
			[_caption.leadingAnchor constraintEqualToAnchor: self.leadingAnchor constant: 6],
			[_caption.trailingAnchor constraintLessThanOrEqualToAnchor: _close.leadingAnchor constant: -4],
			[_close.centerYAnchor constraintEqualToAnchor: _caption.centerYAnchor],
			[_close.trailingAnchor constraintEqualToAnchor: self.trailingAnchor constant: -4],
			[_close.widthAnchor constraintEqualToConstant: 16],
			[_body.topAnchor constraintEqualToAnchor: _caption.bottomAnchor constant: 4],
			[_body.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
			[_body.trailingAnchor constraintEqualToAnchor: self.trailingAnchor],
			[_body.bottomAnchor constraintEqualToAnchor: _tabs.topAnchor],
			[_tabs.leadingAnchor constraintEqualToAnchor: self.leadingAnchor],
			[_tabs.trailingAnchor constraintLessThanOrEqualToAnchor: self.trailingAnchor],
			[_tabs.bottomAnchor constraintEqualToAnchor: self.bottomAnchor],
			_tabsHeight,
		]];
	}
	return self;
}

- (void)setPanels:(NSArray<id<NppDockPanel>>*)panels selected:(NSInteger)selected
{
	_panels = panels;
	_tabs.segmentCount = panels.count;
	for (NSUInteger i = 0; i < panels.count; ++i)
	{
		[_tabs setLabel: panels[i].title forSegment: i];
		[_tabs setWidth: 0 forSegment: i];
	}
	_tabs.hidden = panels.count < 2;
	_tabsHeight.constant = panels.count < 2 ? 0 : 22;
	if (selected >= 0 && selected < (NSInteger)panels.count)
		_tabs.selectedSegment = selected;

	for (NSView* v in [_body.subviews copy])
		[v removeFromSuperview];
	if (selected < 0 || selected >= (NSInteger)panels.count)
		return;
	id<NppDockPanel> p = panels[selected];
	_caption.stringValue = p.title;
	NSView* v = p.view;
	v.translatesAutoresizingMaskIntoConstraints = NO;
	[_body addSubview: v];
	[NSLayoutConstraint activateConstraints: @[
		[v.topAnchor constraintEqualToAnchor: _body.topAnchor],
		[v.leadingAnchor constraintEqualToAnchor: _body.leadingAnchor],
		[v.trailingAnchor constraintEqualToAnchor: _body.trailingAnchor],
		[v.bottomAnchor constraintEqualToAnchor: _body.bottomAnchor],
	]];
}

- (void)closePanel:(id)sender
{
	if (_onClose)
		_onClose();
}

- (void)tabChanged:(id)sender
{
	if (_onSelect)
		_onSelect(_tabs.selectedSegment);
}

@end

@interface NppDockManager () <NSSplitViewDelegate>
@end

@implementation NppDockManager
{
	NSSplitView* _container;
	NSView* _center;
	NppDockContainer* _sides[2];
	NSMutableArray<NSNumber*>* _visible[2];     // shown panels per side, in tab order
	NSInteger _selected[2];
	NSMutableDictionary<NSNumber*, id<NppDockPanel>>* _panels;
	NSMutableDictionary<NSNumber*, NSNumber*>* _sideOf;
	CGFloat _width[2];
}

- (instancetype)initWithCenter:(NSView*)center
{
	if ((self = [super init]))
	{
		_center = center;
		_container = [[NSSplitView alloc] init];
		_container.vertical = YES;
		_container.dividerStyle = NSSplitViewDividerStyleThin;
		_container.delegate = self;
		_container.translatesAutoresizingMaskIntoConstraints = NO;
		[_container addArrangedSubview: center];
		_panels = [NSMutableDictionary dictionary];
		_sideOf = [NSMutableDictionary dictionary];
		for (int s = 0; s < 2; ++s)
		{
			_visible[s] = [NSMutableArray array];
			_width[s] = 260;
			NppDockContainer* c = [[NppDockContainer alloc] initWithFrame: NSMakeRect(0, 0, 260, 400)];
			__weak NppDockManager* weakSelf = self;
			c.onClose = ^{ [weakSelf closeSelectedOnSide: s]; };
			c.onSelect = ^(NSInteger i) { [weakSelf selectIndex: i onSide: s]; };
			_sides[s] = c;
		}
	}
	return self;
}

- (NSSplitView*)container
{
	return _container;
}

- (void)addPanel:(id<NppDockPanel>)panel forCommand:(int)cmd side:(NppDockSide)side
{
	_panels[@(cmd)] = panel;
	_sideOf[@(cmd)] = @(side);
}

- (id<NppDockPanel>)panelForCommand:(int)cmd
{
	return _panels[@(cmd)];
}

- (BOOL)isPanelVisible:(int)cmd
{
	NSNumber* side = _sideOf[@(cmd)];
	return side && [_visible[side.intValue] containsObject: @(cmd)];
}

- (void)showPanel:(int)cmd
{
	NSNumber* sideNum = _sideOf[@(cmd)];
	if (!sideNum)
		return;
	int s = sideNum.intValue;
	if (![_visible[s] containsObject: @(cmd)])
		[_visible[s] addObject: @(cmd)];
	_selected[s] = [_visible[s] indexOfObject: @(cmd)];
	[self refreshSide: s];
	id<NppDockPanel> p = _panels[@(cmd)];
	if ([p respondsToSelector: @selector(panelDidShow)])
		[p panelDidShow];
}

- (void)hidePanel:(int)cmd
{
	NSNumber* sideNum = _sideOf[@(cmd)];
	if (!sideNum)
		return;
	int s = sideNum.intValue;
	NSUInteger i = [_visible[s] indexOfObject: @(cmd)];
	if (i == NSNotFound)
		return;
	[_visible[s] removeObjectAtIndex: i];
	_selected[s] = MIN(_selected[s], (NSInteger)_visible[s].count - 1);
	[self refreshSide: s];
	id<NppDockPanel> p = _panels[@(cmd)];
	if ([p respondsToSelector: @selector(panelDidHide)])
		[p panelDidHide];
}

- (void)togglePanel:(int)cmd
{
	if ([self isPanelVisible: cmd])
		[self hidePanel: cmd];
	else
		[self showPanel: cmd];
}

- (NSArray<NSNumber*>*)visibleCommands
{
	return [_visible[0] arrayByAddingObjectsFromArray: _visible[1]];
}

- (void)closeSelectedOnSide:(int)s
{
	if (_selected[s] >= 0 && _selected[s] < (NSInteger)_visible[s].count)
		[self hidePanel: _visible[s][_selected[s]].intValue];
}

- (void)selectIndex:(NSInteger)i onSide:(int)s
{
	_selected[s] = i;
	[self refreshSide: s];
}

- (void)refreshSide:(int)s
{
	NppDockContainer* c = _sides[s];
	NSMutableArray* panels = [NSMutableArray array];
	for (NSNumber* cmd in _visible[s])
		[panels addObject: _panels[cmd]];
	BOOL shown = c.superview == _container;
	if (shown && c.frame.size.width > 20)
		_width[s] = c.frame.size.width;
	if (panels.count == 0)
	{
		if (shown)
			[c removeFromSuperview];
		[c setPanels: @[] selected: -1];
		return;
	}
	[c setPanels: panels selected: _selected[s]];
	if (!shown)
	{
		if (s == NppDockLeft)
			[_container insertArrangedSubview: c atIndex: 0];
		else
			[_container addArrangedSubview: c];
		[_container layoutSubtreeIfNeeded];
		CGFloat total = _container.bounds.size.width;
		if (s == NppDockLeft)
			[_container setPosition: _width[s] ofDividerAtIndex: 0];
		else
			[_container setPosition: total - _width[s] - _container.dividerThickness ofDividerAtIndex: _container.arrangedSubviews.count - 2];
	}
}

#pragma mark - NSSplitViewDelegate

- (BOOL)splitView:(NSSplitView*)splitView shouldAdjustSizeOfSubview:(NSView*)view
{
	// Window resizes go to the editor, panels keep their width.
	return view == _center;
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i
{
	return MAX(proposed, 80);
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i
{
	return MIN(proposed, splitView.bounds.size.width - 80);
}

@end
