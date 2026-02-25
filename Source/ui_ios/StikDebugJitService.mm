//
//  StikDebugJitService.mm
//  Play! iOS - iOS 26 JIT Support via StikDebug
//
//  Implementation of JIT activation for iOS 26+ with TXM
//

#import "StikDebugJitService.h"
#import <BreakpointJIT/BreakJIT.h>
#include "AppConfig.h"
#import "PreferenceDefs.h"
#import "JITInitializer.h"
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <signal.h>

// CS_DEBUGGED flag
#define CS_DEBUGGED 0x10000000

// csops syscall
static int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize)
{
	return syscall(169, pid, ops, useraddr, usersize);
}

// SIGTRAP handler to prevent crashes
static struct sigaction s_oldTrapAction;
static bool s_trapHandlerInstalled = false;

static void trapHandler(int sig, siginfo_t* info, void* context)
{
	(void)sig;
	(void)info;
	(void)context;
	NSLog(@"[StikDebugJIT] SIGTRAP received - StikDebug may not be attached");
}

@implementation StikDebugJitService
{
	BOOL _initialized;
	BOOL _txmActive;
	float _iosVersion;
}

+ (StikDebugJitService*)sharedService
{
	static StikDebugJitService* sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  sharedInstance = [[self alloc] init];
	});
	return sharedInstance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_initialized = NO;
		_txmActive = NO;
		_iosVersion = 0.0f;
		[self initialize];
	}
	return self;
}

- (void)initialize
{
	if(_initialized) return;

	NSLog(@"[StikDebugJIT] Initializing...");

	// Detect iOS version
	_iosVersion = [self detectIOSVersion];
	NSLog(@"[StikDebugJIT] iOS version: %.1f", _iosVersion);

	// Detect TXM
	_txmActive = [self detectTXM];
	NSLog(@"[StikDebugJIT] TXM active: %@", _txmActive ? @"YES" : @"NO");

	// NOTE: Do NOT install SIGTRAP handler!
	// StikDebug needs to handle the brk #0xf00d breakpoint directly.
	// Installing our own handler interferes with StikDebug's ability to
	// intercept and process the JIT allocation request.

	// Set environment variable for MemoryFunction.cpp
	if(_txmActive && [self isDebuggerAttached])
	{
		setenv("PLAY_HAS_TXM", "1", 1);
		NSLog(@"[StikDebugJIT] Set PLAY_HAS_TXM=1");
	}

	_initialized = YES;
}

- (void)registerPreferences
{
	CAppConfig::GetInstance().RegisterPreferenceBoolean(PREFERENCE_STIKDEBUG_JIT_ENABLED, true);
}

#pragma mark - Detection

- (float)detectIOSVersion
{
	char version[32] = {0};
	size_t size = sizeof(version);

	if(sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0)
	{
		return strtof(version, NULL);
	}
	return 0.0f;
}

- (BOOL)detectTXM
{
	// iOS 26+ required
	if(_iosVersion < 26.0f)
	{
		return NO;
	}

	// --- 1. Check hw.cpufamily against known TXM chips ---
	uint32_t cpufamily = 0;
	size_t cpusize = sizeof(cpufamily);
	if(sysctlbyname("hw.cpufamily", &cpufamily, &cpusize, NULL, 0) == 0)
	{
		switch(cpufamily)
		{
		case 0xDA33D83D: // A15 Bionic
		case 0x8765EDEA: // A16 Bionic
		case 0xFA33415E: // A17 Pro
		case 0x5F4DEA93: // A18
		case 0x72015832: // A18 Pro
		case 0x6F5129AC: // M2
		case 0xDC6E3A2A: // M3
		case 0x041A314C: // M4
			return YES;
		default:
			break;
		}
	}

	// --- 2. Fallback: detect TXM via hw.machine model identifier ---
	char machine[64] = {0};
	size_t machsize = sizeof(machine);
	if(sysctlbyname("hw.machine", machine, &machsize, NULL, 0) == 0)
	{
		int major = 0;
		if(sscanf(machine, "iPhone%d", &major) == 1 && major >= 14)
			return YES;
		if(sscanf(machine, "iPad%d", &major) == 1 && major >= 13)
			return YES;
	}

	return NO;
}

- (BOOL)isDebuggerAttached
{
	uint32_t flags = 0;
	if(csops(getpid(), 0, &flags, sizeof(flags)) == 0)
	{
		return (flags & CS_DEBUGGED) != 0;
	}
	return NO;
}

- (void)installTrapHandler
{
	if(s_trapHandlerInstalled) return;

	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = trapHandler;
	action.sa_flags = SA_SIGINFO;
	sigemptyset(&action.sa_mask);

	if(sigaction(SIGTRAP, &action, &s_oldTrapAction) == 0)
	{
		s_trapHandlerInstalled = true;
		NSLog(@"[StikDebugJIT] SIGTRAP handler installed");
	}
}

#pragma mark - Public API

- (BOOL)hasTXM
{
	return _txmActive;
}

- (float)iosVersion
{
	return _iosVersion;
}

- (BOOL)txmActive
{
	return _txmActive;
}

- (BOOL)isJitAvailable
{
	if(_iosVersion >= 26.0f)
	{
		// iOS 26+: Both LuckTXM and LuckNoTXM require CS_DEBUGGED
		// (vm_protect EXECUTE needs debugger even without TXM)
		return [self isDebuggerAttached];
	}
	return YES; // Legacy path
}

- (BOOL)jitEnabled
{
	return [self isJitAvailable];
}

- (BOOL)isJitActive
{
	return [self isJitAvailable];
}

- (BOOL)needsActivation
{
	if(_iosVersion >= 26.0f)
	{
		// iOS 26+: Both TXM and non-TXM devices need debugger for JIT
		return ![self isDebuggerAttached];
	}
	return NO;
}

- (BOOL)isStikDebugInstalled
{
	NSURL* stikDebugURL = [NSURL URLWithString:@"stikdebug://"];
	return [[UIApplication sharedApplication] canOpenURL:stikDebugURL];
}

- (void)setEnvironmentForJIT
{
	if(_txmActive)
	{
		setenv("PLAY_HAS_TXM", "1", 1);
		NSLog(@"[StikDebugJIT] Set PLAY_HAS_TXM=1");
	}
	if([self isDebuggerAttached])
	{
		setenv("PLAY_JIT_ACTIVE", "1", 1);
		NSLog(@"[StikDebugJIT] Set PLAY_JIT_ACTIVE=1");
	}
}

- (BOOL)handleCallbackURL:(NSURL*)url
{
	NSString* scheme = [url scheme];
	if(![scheme isEqualToString:@"play"] && ![scheme isEqualToString:@"com.virtualapplications.play"])
	{
		return NO;
	}

	NSString* host = [url host];
	if([host isEqualToString:@"jit-enabled"] || [host isEqualToString:@"jit-callback"])
	{
		NSLog(@"[StikDebugJIT] JIT callback received from StikDebug");
		if([self isDebuggerAttached])
		{
			setenv("PLAY_HAS_TXM", "1", 1);
			setenv("PLAY_JIT_ACTIVE", "1", 1);
			NSLog(@"[StikDebugJIT] JIT confirmed active via callback");

			// NOW it's safe to allocate JIT memory - StikDebug is actively listening
			// The URL callback confirms StikDebug's GDB server is running and
			// will intercept the brk #0xf00d breakpoint from BreakGetJITMapping
			NSLog(@"[StikDebugJIT] Triggering JIT allocation after callback...");
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			  [JITInitializer allocateExecutableMemoryIfNeeded];

			  dispatch_async(dispatch_get_main_queue(), ^{
				// Post notification that JIT is ready
				[[NSNotificationCenter defaultCenter]
				    postNotificationName:@"StikDebugJITReadyNotification"
				                  object:nil];
			  });
			});
		}
		return YES;
	}

	return NO;
}

#pragma mark - Activation

- (NSString*)createJITScript
{
	// JavaScript protocol for StikDebug
	return @"\"use strict\";\n"
	        "const CMD_DETACH = 0;\n"
	        "const CMD_PREPARE_REGION = 1;\n"
	        "\n"
	        "function numberToLittleEndianHexString(num) {\n"
	        "    let hex = '';\n"
	        "    for (let i = 0; i < 8; i++) {\n"
	        "        hex += (Number((num >> BigInt(i * 8)) & 0xFFn)).toString(16).padStart(2, '0');\n"
	        "    }\n"
	        "    return hex;\n"
	        "}\n"
	        "\n"
	        "function JIT26PrepareRegion(brkResponse) {\n"
	        "    const registers = brkResponse.split(';');\n"
	        "    let x0 = 0n, x1 = 0n, tid = '';\n"
	        "    for (const reg of registers) {\n"
	        "        if (reg.startsWith('0:')) x0 = BigInt('0x' + reg.slice(2).match(/../g).reverse().join(''));\n"
	        "        if (reg.startsWith('1:')) x1 = BigInt('0x' + reg.slice(2).match(/../g).reverse().join(''));\n"
	        "        if (reg.startsWith('thread:')) tid = reg.slice(7);\n"
	        "    }\n"
	        "    let jitPageAddress = x0;\n"
	        "    if (x0 == 0n) {\n"
	        "        const rxResponse = send_command(`_M${x1.toString(16)},rx`);\n"
	        "        jitPageAddress = BigInt(`0x${rxResponse}`);\n"
	        "    }\n"
	        "    prepare_memory_region(jitPageAddress, x1);\n"
	        "    send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);\n"
	        "}\n"
	        "\n"
	        "function onBreakpoint(brkResponse) {\n"
	        "    const registers = brkResponse.split(';');\n"
	        "    let x16 = 0n;\n"
	        "    for (const reg of registers) {\n"
	        "        if (reg.startsWith('10:')) x16 = BigInt('0x' + reg.slice(3).match(/../g).reverse().join(''));\n"
	        "    }\n"
	        "    if (x16 == BigInt(CMD_DETACH)) {\n"
	        "        send_command('D');\n"
	        "        return;\n"
	        "    }\n"
	        "    if (x16 == BigInt(CMD_PREPARE_REGION)) {\n"
	        "        JIT26PrepareRegion(brkResponse);\n"
	        "    }\n"
	        "    send_command('c');\n"
	        "}\n";
}

- (void)requestActivation:(void (^)(BOOL success))completion
{
	if(_iosVersion < 26.0f)
	{
		NSLog(@"[StikDebugJIT] Legacy iOS - StikDebug activation not needed");
		if(completion) completion(YES);
		return;
	}

	if([self isDebuggerAttached])
	{
		NSLog(@"[StikDebugJIT] Already activated");
		setenv("PLAY_HAS_TXM", "1", 1);
		if(completion) completion(YES);
		return;
	}

	// Check if StikDebug activation is enabled in preferences
	if(!CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_STIKDEBUG_JIT_ENABLED))
	{
		NSLog(@"[StikDebugJIT] StikDebug activation disabled in preferences");
		if(completion) completion(NO);
		return;
	}

	NSString* bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.virtualapplications.play";
	pid_t pid = getpid();
	NSString* script = [self createJITScript];
	NSData* scriptData = [script dataUsingEncoding:NSUTF8StringEncoding];
	NSString* scriptBase64 = [scriptData base64EncodedStringWithOptions:0];

	// URL encode
	scriptBase64 = [scriptBase64 stringByAddingPercentEncodingWithAllowedCharacters:
	                                 [NSCharacterSet URLQueryAllowedCharacterSet]];

	NSString* urlString = [NSString stringWithFormat:
	                                    @"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-name=Play&script-data=%@",
	                                    bundleID, pid, scriptBase64];

	NSURL* url = [NSURL URLWithString:urlString];

	NSLog(@"[StikDebugJIT] Opening StikDebug URL...");

	dispatch_async(dispatch_get_main_queue(), ^{
	  [[UIApplication sharedApplication] openURL:url
		  options:@{}
		  completionHandler:^(BOOL opened) {
			if(!opened)
			{
				NSLog(@"[StikDebugJIT] Failed to open StikDebug - is it installed?");
				if(completion) completion(NO);
				return;
			}

			NSLog(@"[StikDebugJIT] StikDebug opened, waiting for activation...");

			// Wait for debugger
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			  BOOL attached = [self waitForDebugger:5000];

			  dispatch_async(dispatch_get_main_queue(), ^{
				if(attached)
				{
					setenv("PLAY_HAS_TXM", "1", 1);
					NSLog(@"[StikDebugJIT] JIT activated successfully!");
				}
				else
				{
					NSLog(@"[StikDebugJIT] Activation timeout");
				}
				if(completion) completion(attached);
			  });
			});
		  }];
	});
}

- (void)requestActivationWithCompletion:(void (^)(BOOL success, NSError* error))completion
{
	[self requestActivation:^(BOOL success) {
	  if(completion)
	  {
		  NSError* error = nil;
		  if(!success)
		  {
			  error = [NSError errorWithDomain:@"com.virtualapplications.play.jit"
				                          code:-1
				                      userInfo:@{NSLocalizedDescriptionKey : @"Failed to activate JIT. Make sure StikDebug is installed and try again."}];
		  }
		  completion(success, error);
	  }
	}];
}

- (BOOL)waitForDebugger:(uint32_t)timeout_ms
{
	uint32_t elapsed = 0;
	const uint32_t interval = 50;

	while(elapsed < timeout_ms)
	{
		if([self isDebuggerAttached])
		{
			return YES;
		}
		usleep(interval * 1000);
		elapsed += interval;
	}
	return [self isDebuggerAttached];
}

- (void)detachDebugger
{
	if(_txmActive && [self isDebuggerAttached])
	{
		BreakJITDetach();
		NSLog(@"[StikDebugJIT] Debugger detached");
	}
}

@end
