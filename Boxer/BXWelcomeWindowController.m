/* 
 Boxer is copyright 2010 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/GNU General Public License.txt, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXWelcomeWindowController.h"
#import "BXAppController.h"
#import "BXValueTransformers.h"
#import "BXWelcomeView.h"
#import "BXImport.h"


//The height of the bottom window border.
//TODO: determine this from NIB content.
#define BXWelcomeWindowBorderThickness 40.0f

#define BXDocumentStartTag 1
#define BXDocumentEndTag 2


#pragma mark -
#pragma mark Private methods

@interface BXWelcomeWindowController ()

//Handle file drag-drop onto the Import Game/Open DOS Prompt buttons.
- (BOOL) _canOpenFilePaths: (NSArray *)filePaths;
- (BOOL) _canImportFilePaths: (NSArray *)filePaths;
- (void) _openFilePaths: (NSArray *)filePaths;
- (void) _importFilePaths: (NSArray *)filePaths;

@end


@implementation BXWelcomeWindowController
@synthesize recentDocumentsButton, importGameButton, openPromptButton;

#pragma mark -
#pragma mark Initialization and deallocation

+ (void) initialize
{
	BXImageSizeTransformer *welcomeButtonImageSize = [[BXImageSizeTransformer alloc] initWithSize: NSMakeSize(128, 128)];
	[NSValueTransformer setValueTransformer: welcomeButtonImageSize forName: @"BXWelcomeButtonImageSize"];
	[welcomeButtonImageSize release];
}

+ (id) controller
{
	static id singleton = nil;
	
	if (!singleton) singleton = [[self alloc] initWithWindowNibName: @"Welcome"];
	return singleton;
}

- (void) dealloc
{
	[self setRecentDocumentsButton: nil], [recentDocumentsButton release];
	[super dealloc];
}

- (void) windowDidLoad
{
	[[self window] setContentBorderThickness: BXWelcomeWindowBorderThickness + 1 forEdge: NSMinYEdge];
	
	//Set up drag-drop events for the buttons
	NSArray *types = [NSArray arrayWithObject: NSFilenamesPboardType];
	[[self importGameButton] registerForDraggedTypes: types];
	[[self openPromptButton] registerForDraggedTypes: types];
	
	[[self window] setAcceptsMouseMovedEvents: YES];
}


#pragma mark -
#pragma mark UI actions

- (IBAction) openRecentDocument: (NSMenuItem *)sender
{
	NSURL *url = [sender representedObject];
	
	[[NSApp delegate] openDocumentWithContentsOfURL: url display: YES error: NULL];
}


#pragma mark -
#pragma mark Open Recent menu

- (void) menuWillOpen: (NSMenu *)menu
{
	NSArray *documents = [[NSApp delegate] recentDocumentURLs];
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSFileManager *manager = [NSFileManager defaultManager];
	
	//Delete all document items
	NSUInteger startOfDocuments	= [menu indexOfItemWithTag: BXDocumentStartTag] + 1;
	NSUInteger endOfDocuments	= [menu indexOfItemWithTag: BXDocumentEndTag];
	NSRange documentRange		= NSMakeRange(startOfDocuments, endOfDocuments - startOfDocuments);

	for (NSMenuItem *oldItem in [[menu itemArray] subarrayWithRange: documentRange])
		[menu removeItem: oldItem];
	
	//Then, repopulate it with the recent documents
	NSUInteger insertionPoint = startOfDocuments;
	for (NSURL *url in documents)
	{
		NSAutoreleasePool *pool	= [[NSAutoreleasePool alloc] init];
		NSMenuItem *item		= [[NSMenuItem alloc] init];
		
		[item setRepresentedObject: url];
		[item setTarget: self];
		[item setAction: @selector(openRecentDocument:)];
		
		NSString *path	= [url path];
		NSImage *icon	= [workspace iconForFile: path];
		NSString *title	= [manager displayNameAtPath: path];
		
		[icon setSize: NSMakeSize(16, 16)];
		[item setImage: icon];
		[item setTitle: title];
		
		[menu insertItem: item atIndex: insertionPoint++];
		
		[item release];
		[pool drain];
	}
	//Finish off the list with a separator
	if ([documents count])
		[menu insertItem: [NSMenuItem separatorItem] atIndex: insertionPoint];
}


#pragma mark -
#pragma mark Drag-drop behaviours

- (BOOL) _canOpenFilePaths: (NSArray *)filePaths
{
	for (NSString *path in filePaths)
	{
		//If any of the files were not of a recognised type, bail out
		if (![[NSApp delegate] typeForContentsOfURL: [NSURL fileURLWithPath: path] error: NULL]) return NO;
	}
	return YES;
}

- (BOOL) _canImportFilePaths: (NSArray *)filePaths
{
	for (NSString *path in filePaths)
	{
		if (![BXImport canImportFromSourcePath: path]) return NO;
	}
	return YES;
}

- (void) _openFilePaths: (NSArray *)filePaths
{
	for (NSString *filePath in filePaths)
	{
		[[NSApp delegate] openDocumentWithContentsOfURL: [NSURL fileURLWithPath: filePath]
												display: YES
												  error: NULL];
	}
}

- (void) _importFilePaths: (NSArray *)filePaths
{
	//Import only the first file, since we can't (and don't want to) support
	//multiple concurrent import sessions
	NSString *importPath = [filePaths objectAtIndex: 0];
	BXImport *importer = [[NSApp delegate] openImportSessionAndDisplay: YES error: NULL];
	[importer importFromSourcePath: importPath];
}

- (NSDragOperation) button: (BXWelcomeButton *)button draggingEntered: (id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = [sender draggingPasteboard]; 
	
	if ([[pboard types] containsObject: NSFilenamesPboardType])
	{
		NSArray *filePaths = [pboard propertyListForType: NSFilenamesPboardType];
		
		//Check that we can actually open the files being dropped
		if (button == [self importGameButton] && ![self _canImportFilePaths: filePaths]) return NO;
		if (button == [self openPromptButton] && ![self _canOpenFilePaths: filePaths]) return NO;
		
		//If so, highlight the button and go for it
		[[button cell] setHovered: YES];
		return NSDragOperationGeneric;
	}
	else return NSDragOperationNone;
}

- (void) button: (BXWelcomeButton *)button draggingExited: (id <NSDraggingInfo>)sender
{
	[[button cell] setHovered: NO];
}

- (BOOL) button: (BXWelcomeButton *)button performDragOperation: (id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = [sender draggingPasteboard];
	[[button cell] setHovered: NO];
	
	if ([[pboard types] containsObject: NSFilenamesPboardType])
	{
		NSArray *filePaths = [pboard propertyListForType: NSFilenamesPboardType];
		
		if (button == [self importGameButton])		[self _importFilePaths: filePaths];
		else if (button == [self openPromptButton]) [self _openFilePaths: filePaths];
		
		return YES;
	}
	else return NO;
}


@end