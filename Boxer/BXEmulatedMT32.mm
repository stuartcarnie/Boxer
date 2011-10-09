/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatedMT32.h"
#import "RegexKitLite.h"
#import "MT32Emu/Synth.h"
#import "MT32Emu/Filestream.h"
#import "BXEmulatedMT32Delegate.h"
#import "mixer.h"


#pragma mark -
#pragma mark Private constants

NSString * const BXEmulatedMT32ErrorDomain = @"BXEmulatedMT32ErrorDomain";
NSString * const BXMT32ControlROMTypeKey = @"BXMT32ControlROMTypeKey";
NSString * const BXMT32PCMROMTypeKey = @"BXMT32PCMROMTypeKey";


#define BXMT32ControlROMSize    64 * 1024
#define BXMT32PCMROMSize        512 * 1024
#define BXCM32LPCMROMSize       1024 * 1024



#pragma mark -
#pragma mark Private method declarations

@interface BXEmulatedMT32 ()
@property (retain, nonatomic) NSError *synthError;

- (BOOL) _prepareMT32EmulatorWithError: (NSError **)outError;
- (void) _renderOutputForLength: (NSUInteger)length;
- (NSString *) _pathToROMMatchingName: (NSString *)ROMName;
- (void) _reportMT32MessageOfType: (MT32Emu::ReportType)type data: (const void *)reportData;

//Callbacks for MT32Emu::Synth and DOSBox mixer
MT32Emu::File * _openMT32ROM(void *userData, const char *filename);
void _closeMT32ROM(void *userData, MT32Emu::File *file);
int _reportMT32Message(void *userData, MT32Emu::ReportType type, const void *reportData);
void _logMT32DebugMessage(void *userData, const char *fmt, va_list list);
void _renderOutput(Bitu len);

@end


#pragma mark -
#pragma mark Implementation

@implementation BXEmulatedMT32
@synthesize delegate = _delegate;
@synthesize PCMROMPath = _PCMROMPath, controlROMPath = _controlROMPath;
@synthesize synthError = _synthError;


//Used by the DOSBox mixer, to flag the active MT-32 instance to which we should send the callback.
BXEmulatedMT32 *_currentEmulatedMT32;
//Used to track the single mixer channel to which the active MT-32 instance will mix.
MixerChannel *_mixerChannel;

#pragma mark -
#pragma mark ROM validation methods

+ (unsigned long long) PCMSizeForROMType: (BXMT32ROMType)ROMType
{
    if (ROMType == BXMT32ROMTypeCM32L) return 1024 * 1024;
    else return 512 * 1024;
}

+ (BXMT32ROMType) typeOfControlROMAtPath: (NSString *)path
                                   error: (NSError **)outError
{
    if (outError) *outError = nil;
    
    if (!path)
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                            code: BXEmulatedMT32MissingROM
                                        userInfo: nil];
        }
        return BXMT32ROMTypeUnknown;
    }
    
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath: path];
	
	//File could not be opened for reading, bail out
	if (!file)
	{
		if (outError)
		{
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject: path
                                                                 forKey: NSFilePathErrorKey];
			*outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
											code: BXEmulatedMT32CouldNotReadROM
										userInfo: userInfo];
		}
		return BXMT32ROMTypeUnknown;
	}

    @try
    {
        //Measure how large the control ROM is
        [file seekToEndOfFile];
        unsigned long long fileSize = [file offsetInFile];
        [file seekToFileOffset: 0];
        
        //If the file matches our expected size for control ROMs, check what ROM type it is
        if (fileSize == BXMT32ControlROMSize)
        {
            NSString *ROMProfilePath = [[NSBundle mainBundle] pathForResource: @"MT32ROMTypes" ofType: @"plist"];
            NSArray *ROMProfiles = [NSArray arrayWithContentsOfFile: ROMProfilePath];
            
            for (NSDictionary *profile in ROMProfiles)
            {
                NSData *nameBytes = [[profile objectForKey: @"name"] dataUsingEncoding: NSASCIIStringEncoding];
                NSUInteger nameOffset = [[profile objectForKey: @"nameOffset"] unsignedIntegerValue];
                
                [file seekToFileOffset: nameOffset];
                NSData *bytesInROM = [file readDataOfLength: [nameBytes length]];
                
                if ([bytesInROM isEqualToData: nameBytes])
                    return [[profile objectForKey: @"type"] unsignedIntegerValue];
            }
        }
    }
    //If we couldn't read data at any point, then bail out with an error. 
    @catch (NSException *exception)
    {
        if (outError)
		{
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject: path forKey: NSFilePathErrorKey];
			*outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
											code: BXEmulatedMT32CouldNotReadROM
										userInfo: userInfo];
		}
        return BXMT32ROMTypeUnknown;
    }
    
    //If we got this far, the control ROM was the wrong size or not recognised as any of our known types.
    if (outError)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject: path
                                                             forKey: NSFilePathErrorKey];
        
        *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                        code: BXEmulatedMT32InvalidROM
                                    userInfo: userInfo];
    }
    return nil;
}

+ (BXMT32ROMType) typeOfPCMROMAtPath: (NSString *)path
                               error: (NSError **)outError
{
    if (outError) *outError = nil;
    
    if (!path)
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                            code: BXEmulatedMT32MissingROM
                                        userInfo: nil];
        }
        return BXMT32ROMTypeUnknown;
    }
    
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath: path];
	
	//File could not be opened for reading, bail out
	if (!file)
	{
		if (outError)
		{
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject: path forKey: NSFilePathErrorKey];
			*outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
											code: BXEmulatedMT32CouldNotReadROM
										userInfo: userInfo];
		}
		return BXMT32ROMTypeUnknown;
	}
    
    //Measure how large the file is, to determine what type of ROM it should be.
    //(It would be nice if we had a more authoritative heuristic than this, but
    //that's all MT32Emu::Synth uses to determine ROM viability.)
    
    [file seekToEndOfFile];
    unsigned long long fileSize = [file offsetInFile];
    [file seekToFileOffset: 0];
    
    if      (fileSize == BXMT32PCMROMSize)  return BXMT32ROMTypeMT32;
    else if (fileSize == BXCM32LPCMROMSize) return BXMT32ROMTypeCM32L;
    else
    {
        if (outError)
        {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject: path forKey: NSFilePathErrorKey];
            *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                            code: BXEmulatedMT32InvalidROM
                                        userInfo: userInfo];
        }
        return BXMT32ROMTypeUnknown;
    } 
}

+ (BXMT32ROMType) typeofROMPairWithControlROMPath: (NSString *)controlROMPath
                                       PCMROMPath: (NSString *)PCMROMPath 
                                            error: (NSError **)outError
{
    NSError *controlError = nil, *PCMError = nil;
    
    //Validate both ROMs individually.
    BXMT32ROMType controlType   = [self typeOfControlROMAtPath: controlROMPath
                                                         error: (outError) ? &controlError : nil];
    
    BXMT32ROMType PCMType       = [self typeOfPCMROMAtPath: PCMROMPath
                                                     error: (outError) ? &PCMError : nil];
    
    //If the ROM types could be determined and did match, we have a winner
    if (controlType != BXMT32ROMTypeUnknown && controlType == PCMType) return controlType;
    
    //Otherwise, work out what went wrong
    else
    {
        if (outError)
        {   
            //If one or the other ROM was invalid, then treat that as the canonical error.
            if ([[controlError domain] isEqualToString: BXEmulatedMT32ErrorDomain] && [controlError code] == BXEmulatedMT32InvalidROM) *outError = controlError; 
            
            else if ([[PCMError domain] isEqualToString: BXEmulatedMT32ErrorDomain] && [controlError code] == BXEmulatedMT32InvalidROM) *outError = PCMError; 
            
            //Otherwise, return the first error we got.
            else if (controlError) *outError = controlError;
            else if (PCMError) *outError = PCMError;
            
            //If there were no actual errors, but the ROM types didn't match,
            //then flag this as a mismatch.
            else
            {
                NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                          [NSNumber numberWithInteger: controlType], BXMT32ControlROMTypeKey,
                                          [NSNumber numberWithInteger: PCMType], BXMT32PCMROMTypeKey,
                                          nil];
                
                *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                                code: BXEmulatedMT32MismatchedROMs
                                            userInfo: userInfo];
            }
        }
        return BXMT32ROMTypeUnknown;
    }
}


#pragma mark -
#pragma mark Initialization and deallocation

- (id <BXMIDIDevice>) initWithPCMROM: (NSString *)PCMROM
                          controlROM: (NSString *)controlROM
                            delegate: (id <BXEmulatedMT32Delegate>)delegate
                               error: (NSError **)outError
{
    if ((self = [self init]))
    {
        [self setPCMROMPath: PCMROM];
        [self setControlROMPath: controlROM];
        [self setDelegate: delegate];
        
        if (![self _prepareMT32EmulatorWithError: outError])
        {
            [self release];
            self = nil;
        }
        else
        {
            _currentEmulatedMT32 = self;
        }
    }
    return self;
}

- (void) close
{
    if (_synth)
    {
        _synth->close();
        delete _synth;
        _synth = NULL;
    }
    
    if (_currentEmulatedMT32 == self)
    {
        _currentEmulatedMT32 = nil;
        if (_mixerChannel)
        {
            _mixerChannel->Enable(false);
            MIXER_DelChannel(_mixerChannel);
            _mixerChannel = NULL;
        }
    }
}

- (void) dealloc
{
    [self close];
    
    [self setSynthError: nil], [_synthError release];
    [self setPCMROMPath: nil], [_PCMROMPath release];
    [self setControlROMPath: nil], [_controlROMPath release];
    
    [super dealloc];
}


#pragma mark -
#pragma mark MIDI processing and status

- (BOOL) supportsMT32Music          { return YES; }
- (BOOL) supportsGeneralMIDIMusic   { return NO; }

//Since we're processing on the same thread, the emulator is always ready to go
- (BOOL) isProcessing       { return NO; }
- (NSDate *) dateWhenReady  { return [NSDate distantPast]; }


- (void) handleMessage: (NSData *)message
{
    NSAssert(_synth, @"handleMessage: called before successful initialization.");
    NSAssert([message length] > 0, @"0-length message received by handleMessage:");
    
    //MT32Emu's playMsg takes standard 3-byte MIDI messages as a 32-bit integer, which
    //is a terrible idea, but there you go. We need to pack our byte array into such
    //an integer, allowing for the differing endianness on PowerPC Macs.
    UInt8 *contents = (UInt8 *)[message bytes];
    UInt8 status = contents[0];
    UInt8 data1 = ([message length] > 1) ? contents[1] : 0;
    UInt8 data2 = ([message length] > 2) ? contents[2] : 0;
    
    UInt8 paddedMsg[4] = { status, data1, data2, 0};
    UInt32 intMsg = ((UInt32 *)paddedMsg)[0];
    
    _synth->playMsg(CFSwapInt32LittleToHost(intMsg));
}

- (void) handleSysex: (NSData *)message
{
    NSAssert(_synth, @"handleSysEx: called before successful initialization.");
    NSAssert([message length] > 0, @"0-length message received by handleSysex:");
    
    _synth->playSysex((UInt8 *)[message bytes], [message length]);
}

- (void) resume
{
    NSAssert(_mixerChannel, @"resume called before successful initialization.");
    _mixerChannel->Enable(YES);
}

- (void) pause
{
    NSAssert(_mixerChannel, @"pause called before successful initialization.");
    _mixerChannel->Enable(NO);
}


#pragma mark -
#pragma mark Private methods

- (BOOL) _prepareMT32EmulatorWithError: (NSError **)outError
{
    //Bail out early if we haven't been told where to find the necessary ROMs
    if (![self PCMROMPath] || ![self controlROMPath])
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                            code: BXEmulatedMT32MissingROM
                                        userInfo: nil];
        }
        return NO;
    }
    
    _synth = new MT32Emu::Synth();
    
    MT32Emu::SynthProperties properties;
    
    properties.userData = self;
    properties.report = &_reportMT32Message;
    properties.openFile = &_openMT32ROM;
    properties.closeFile = &_closeMT32ROM;
    properties.printDebug = &_logMT32DebugMessage;
    properties.sampleRate = 32000;
    properties.baseDir = NULL;
    
    if (!_synth->open(properties))
    {
        //Pick up the initialization error we'll have received from
        //the callback, and post it back upstream
        if (outError) *outError = [self synthError];

        delete _synth;
        return NO;
    }
    
    if (!_mixerChannel)
    {
        _mixerChannel = MIXER_AddChannel(_renderOutput, properties.sampleRate, "MT32");
        _mixerChannel->Enable(YES);
    }
    
    return YES;
}

- (void) _renderOutputForLength: (NSUInteger)length
{
    NSAssert(_synth && _mixerChannel, @"_renderOutputForLength: called before successful initialization.");
    
    Bit16s buffer[MIXER_BUFSIZE];
    
    _synth->render(buffer, length);
    _mixerChannel->AddSamples_s16(length, buffer);
}

- (NSString *) _pathToROMMatchingName: (NSString *)ROMName
{
    ROMName = [ROMName lowercaseString];
    if ([ROMName isMatchedByRegex: @"control"])
    {
        return [self controlROMPath];
    }
    else if ([ROMName isMatchedByRegex: @"pcm"])
    {
        return [self PCMROMPath];
    }
    else return nil;
}

- (void) _reportMT32MessageOfType: (MT32Emu::ReportType)type data: (const void *)reportData
{
    if (type == MT32Emu::ReportType_lcdMessage)
    {
        //Pass on LCD messages to our delegate
        NSString *message = [NSString stringWithUTF8String: (const char *)reportData];
        [[self delegate] emulatedMT32: self didDisplayMessage: message];
    }
    else if (type == MT32Emu::ReportType_errorControlROM || type == MT32Emu::ReportType_errorPCMROM)
    {
        //If ROM loading failed, record the error that occurred so we can retrieve it back in the initializer.
        NSString *ROMPath = (type == MT32Emu::ReportType_errorControlROM) ? [self controlROMPath] : [self PCMROMPath]; 
        NSDictionary *userInfo = ROMPath ? [NSDictionary dictionaryWithObject: ROMPath forKey: NSFilePathErrorKey] : nil;
        
        [self setSynthError: [NSError errorWithDomain: BXEmulatedMT32ErrorDomain
                                                 code: BXEmulatedMT32InvalidROM
                                             userInfo: userInfo]];
    }
    else
    {
#ifdef BOXER_DEBUG
        NSLog(@"MT-32 message of type: %d", type);
#endif
    }
}


#pragma mark -
#pragma mark C++-facing callbacks


MT32Emu::File * _openMT32ROM(void *userData, const char *filename)
{
    NSString *requestedROMName = [NSString stringWithUTF8String: filename];
    NSString *ROMPath = [(BXEmulatedMT32 *)userData _pathToROMMatchingName: requestedROMName];
    
    if (ROMPath)
    {
        MT32Emu::FileStream *file = new MT32Emu::FileStream();
        if (!file->open([ROMPath fileSystemRepresentation]))
        {
            delete file;
            return NULL;
        }
        else return file;
    }
    else return NULL;
}

void _closeMT32ROM(void *userData, MT32Emu::File *file)
{
    file->close();
}

int _reportMT32Message(void *userData, MT32Emu::ReportType type, const void *reportData)
{
    [(BXEmulatedMT32 *)userData _reportMT32MessageOfType: type data: reportData];
    return 0;
}

void _logMT32DebugMessage(void *userData, const char *fmt, va_list list)
{
#ifdef BOXER_DEBUG
    NSLogv([NSString stringWithUTF8String: fmt], list);
#endif
}

//Called periodically by DOSBox's mixer to fill its buffer with audio data.
void _renderOutput(Bitu len)
{
    //We need to use a hacky global variable for this because DOSBox's mixer
    //doesn't pass any context with its callbacks.
    [_currentEmulatedMT32 _renderOutputForLength: len];
}

@end