//
//  StikDebugJitService.mm
//  Play! iOS - iOS 26 JIT Support via StikDebug
//
//  Implementation of JIT activation for iOS 26+ with TXM
//

#import "StikDebugJitService.h"
#import <BreakpointJIT/BreakpointJIT.h>
#include "AppConfig.h"
#import "PreferenceDefs.h"
#include <sys/sysctl.h>
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
		// DO NOT call [self initialize] here - causes crash at startup
		// Will be initialized lazily when first accessed
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

	// Install SIGTRAP handler
	[self installTrapHandler];

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
	// Check environment variable first (can be set by user or StikDebug)
	const char* env = getenv("HAS_TXM");
	if(env && strcmp(env, "1") == 0)
	{
		return YES;
	}

	// iOS 26+ required
	if(_iosVersion < 26.0f)
	{
		return NO;
	}

	// Check chip (A14+ / M2+ have TXM on iOS 26)
	uint32_t cpufamily = 0;
	size_t size = sizeof(cpufamily);
	if(sysctlbyname("hw.cpufamily", &cpufamily, &size, NULL, 0) == 0)
	{
		switch(cpufamily)
		{
		case 0x07D34B9F: // A14 Bionic (iPhone 12, iPad Air 4)
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

	// No fallback mmap test - too risky at startup
	// If chip is unknown, assume no TXM (user can set HAS_TXM=1 env var if needed)
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
	[self initialize]; // Lazy init
	return _txmActive;
}

- (float)iosVersion
{
	[self initialize]; // Lazy init
	return _iosVersion;
}

- (BOOL)txmActive
{
	[self initialize]; // Lazy init
	return _txmActive;
}

- (BOOL)isJitAvailable
{
	[self initialize]; // Lazy init
	if(!_txmActive)
	{
		return YES; // No TXM = JIT always available
	}
	return [self isDebuggerAttached];
}

- (BOOL)jitEnabled
{
	[self initialize]; // Lazy init
	return [self isJitAvailable];
}

- (BOOL)needsActivation
{
	[self initialize]; // Lazy init
	return _txmActive && ![self isDebuggerAttached];
}

#pragma mark - Activation

- (NSString*)createJITScript
{
	// Complete JavaScript protocol for StikDebug with BreakpointJIT support
	return @"\"use strict\";\n"
	        "const CMD_DETACH = 0;\n"
	        "const CMD_PREPARE_REGION = 1;\n"
	        "const BRK_IMMEDIATE = 0xf00d;\n"
	        "\n"
	        "function littleEndianHexStringToNumber(hexStr) {\n"
	        "    const bytes = [];\n"
	        "    for (let i = 0; i < hexStr.length; i += 2) {\n"
	        "        bytes.push(parseInt(hexStr.substr(i, 2), 16));\n"
	        "    }\n"
	        "    let num = 0n;\n"
	        "    for (let i = 4; i >= 0; i--) {\n"
	        "        num = (num << 8n) | BigInt(bytes[i]);\n"
	        "    }\n"
	        "    return num;\n"
	        "}\n"
	        "\n"
	        "function numberToLittleEndianHexString(num) {\n"
	        "    const bytes = [];\n"
	        "    for (let i = 0; i < 5; i++) {\n"
	        "        bytes.push(Number(num & 0xFFn));\n"
	        "        num >>= 8n;\n"
	        "    }\n"
	        "    while (bytes.length < 8) {\n"
	        "        bytes.push(0);\n"
	        "    }\n"
	        "    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');\n"
	        "}\n"
	        "\n"
	        "function littleEndianHexToU32(hexStr) {\n"
	        "    return parseInt(hexStr.match(/../g).reverse().join(''), 16);\n"
	        "}\n"
	        "\n"
	        "function extractBrkImmediate(u32) {\n"
	        "    return (u32 >> 5) & 0xFFFF;\n"
	        "}\n"
	        "\n"
	        "function attach() {\n"
	        "    let pid = get_pid();\n"
	        "    log(`Play! JIT: pid = ${pid}`);\n"
	        "    let attachResponse = send_command(`vAttach;${pid.toString(16)}`);\n"
	        "    log(`Play! JIT: attach_response = ${attachResponse}`);\n"
	        "    \n"
	        "    let breakpointCount = 0;\n"
	        "    let shouldContinue = true;\n"
	        "\n"
	        "    while (shouldContinue) {\n"
	        "        breakpointCount++;\n"
	        "        log(`Play! JIT: Handling breakpoint ${breakpointCount}`);\n"
	        "        \n"
	        "        let brkResponse = send_command(`c`);\n"
	        "        log(`Play! JIT: brkResponse = ${brkResponse}`);\n"
	        "        \n"
	        "        let tidMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);\n"
	        "        let tid = tidMatch ? tidMatch.groups['tid'] : null;\n"
	        "        let pcMatch = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse);\n"
	        "        let pc = pcMatch ? pcMatch.groups['reg'] : null;\n"
	        "        let x0Match = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse);\n"
	        "        let x0 = x0Match ? x0Match.groups['reg'] : null;\n"
	        "        let x1Match = /01:(?<reg>[0-9a-f]{16});/.exec(brkResponse);\n"
	        "        let x1 = x1Match ? x1Match.groups['reg'] : null;\n"
	        "        let x16Match = /10:(?<reg>[0-9a-f]{16});/.exec(brkResponse);\n"
	        "        let x16 = x16Match ? x16Match.groups['reg'] : null;\n"
	        "        \n"
	        "        if (!tid || !pc) {\n"
	        "            log(`Play! JIT: Failed to extract registers: tid=${tid}, pc=${pc}`);\n"
	        "            continue;\n"
	        "        }\n"
	        "        \n"
	        "        const pcNum = littleEndianHexStringToNumber(pc);\n"
	        "        const x0Num = x0 ? littleEndianHexStringToNumber(x0) : 0n;\n"
	        "        const x1Num = x1 ? littleEndianHexStringToNumber(x1) : 0n;\n"
	        "        const x16Num = x16 ? littleEndianHexStringToNumber(x16) : 0n;\n"
	        "        \n"
	        "        log(`Play! JIT: tid=${tid}, pc=0x${pcNum.toString(16)}, x16=${x16Num}`);\n"
	        "        \n"
	        "        let instructionResponse = send_command(`m${pcNum.toString(16)},4`);\n"
	        "        log(`Play! JIT: instruction at pc: ${instructionResponse}`);\n"
	        "        let instrU32 = littleEndianHexToU32(instructionResponse);\n"
	        "        let brkImmediate = extractBrkImmediate(instrU32);\n"
	        "        log(`Play! JIT: BRK immediate: 0x${brkImmediate.toString(16)}`);\n"
	        "        \n"
	        "        if (brkImmediate !== BRK_IMMEDIATE) {\n"
	        "            log(`Play! JIT: Skipping - not brk #0xf00d (was 0x${brkImmediate.toString(16)})`);\n"
	        "            continue;\n"
	        "        }\n"
	        "        \n"
	        "        if (x16Num === BigInt(CMD_DETACH)) {\n"
	        "            log(`Play! JIT: CMD_DETACH - detaching debugger`);\n"
	        "            let detachResponse = send_command(`D`);\n"
	        "            log(`Play! JIT: detachResponse = ${detachResponse}`);\n"
	        "            shouldContinue = false;\n"
	        "            break;\n"
	        "        }\n"
	        "        else if (x16Num === BigInt(CMD_PREPARE_REGION)) {\n"
	        "            log(`Play! JIT: CMD_PREPARE_REGION (size=${x1Num})`);\n"
	        "            \n"
	        "            let requestRXResponse = send_command(`_M${x1Num.toString(16)},rx`);\n"
	        "            log(`Play! JIT: requestRXResponse = ${requestRXResponse}`);\n"
	        "            \n"
	        "            if (!requestRXResponse || requestRXResponse.length === 0) {\n"
	        "                log(`Play! JIT: Failed to allocate RX memory`);\n"
	        "                continue;\n"
	        "            }\n"
	        "            \n"
	        "            let jitPageAddress = BigInt(`0x${requestRXResponse}`);\n"
	        "            log(`Play! JIT: Allocated at 0x${jitPageAddress.toString(16)}`);\n"
	        "            \n"
	        "            let prepareResponse = prepare_memory_region(jitPageAddress, x1Num);\n"
	        "            log(`Play! JIT: prepareResponse = ${prepareResponse}`);\n"
	        "            \n"
	        "            let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);\n"
	        "            log(`Play! JIT: putX0Response = ${putX0Response}`);\n"
	        "            \n"
	        "            let pcPlus4 = numberToLittleEndianHexString(pcNum + 4n);\n"
	        "            let pcPlus4Response = send_command(`P20=${pcPlus4};thread:${tid};`);\n"
	        "            log(`Play! JIT: pcPlus4Response = ${pcPlus4Response}`);\n"
	        "            \n"
	        "            log(`Play! JIT: Completed CMD_PREPARE_REGION`);\n"
	        "        }\n"
	        "        else {\n"
	        "            log(`Play! JIT: Unknown command in x16: ${x16Num}`);\n"
	        "        }\n"
	        "    }\n"
	        "    \n"
	        "    log(`Play! JIT: Setup complete - processed ${breakpointCount} breakpoints`);\n"
	        "}\n"
	        "\n"
	        "attach();\n";
}

- (void)requestActivation:(void (^)(BOOL success))completion
{
	[self initialize]; // Lazy init

	if(!_txmActive)
	{
		NSLog(@"[StikDebugJIT] No TXM - activation not needed");
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
	[self initialize]; // Lazy init

	if(_txmActive && [self isDebuggerAttached])
	{
		BreakJITDetach();
		NSLog(@"[StikDebugJIT] Debugger detached");
	}
}

@end
