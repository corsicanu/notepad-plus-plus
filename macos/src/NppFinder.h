// "Search results" window: port of PowerEditor's Finder. Shows Find All
// hits with the searchResult lexer; double-click jumps to the hit.
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

#include "NppSearchEngine.h"

@class NppFinder;

@protocol NppFinderDelegate <NSObject>
// Opens/activates `path` (or an untitled buffer by name); returns the editor showing it, nil on failure.
- (ScintillaView*)finder:(NppFinder*)finder openDocument:(NSString*)path;
- (void)finderDidRequestClose:(NppFinder*)finder;
@end

@interface NppFinder : NSView

@property (nonatomic, weak) id<NppFinderDelegate> delegate;
@property (nonatomic, readonly) ScintillaView* view;
@property (nonatomic) BOOL purgeBeforeSearch;

- (void)applyStyles;

- (void)beginNewFilesSearch;
- (void)addSearchLine:(const std::string&)searchName;
- (void)addFileNameTitle:(const std::string&)fileName;
- (void)addHit:(const FoundHit&)hit file:(const std::string&)fullPath;
- (void)addFileHitCount:(int)count;
- (void)finishFilesSearch:(int)count searched:(int)searchedCount entire:(BOOL)entire options:(const FindOption&)opt;

- (void)gotoNextFoundResult:(int)direction;
- (void)removeAll;

@end
