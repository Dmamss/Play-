//
//  JITManager.mm
//  Play
//
//  Unified JIT Manager Implementation
//  Priority: 1. Debugger → 2. DualMapping → 3. AltServer
//

#import "JITManager.h"
#import "DualMapping.h"
#import "../AltServerJitService.h"
#import <os/log.h>
#import <sys/mman.h>
#import <sys/sysctl.h>

NSNotificationName const JITStatusDidChangeNotification = @"JITStatusDidChangeNotification";

static os_log_t GetJITManagerLog(void)
{
	static os_log_t log = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  log = os_log_create("com.virtualapplications.play", "JITManager");
	});
	return log;
}

#define JIT_LOG_INFO(fmt, ...) os_log_info(GetJITManagerLog(), fmt, ##__VA_ARGS__)
#define JIT_LOG_ERROR(fmt, ...) os_log_error(GetJITManagerLog(), fmt, ##__VA_ARGS__)
#define JIT_LOG_DEBUG(fmt, ...) os_log_debug(GetJITManagerLog(), fmt, ##__VA_ARGS__)

@interface JITManager ()
@property(nonatomic, readwrite) JITStatus status;
@property(nonatomic, readwrite) JITMethod activeMethod;
@property(nonatomic, readwrite) BOOL isJITEnabled;
@property(nonatomic, readwrite, copy) NSString* statusDescription;
@property(nonatomic, readwrite, copy) NSString* methodName;
@end

@implementation JITManager

#pragma mark - Singleton

+ (JITManager*)sharedManager
{
	static JITManager* instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  instance = [[JITManager alloc] init];
	});
	return instance;
}

- (instancetype)init
{
	self = [super init];
	if(self)
	{
		_status = JITStatusUnknown;
		_activeMethod = JITMethodNone;
		_isJITEnabled = NO;
		_statusDescription = @"Not initialized";
		_methodName = @"None";
	}
	return self;
}

#pragma mark - Initialization

- (BOOL)initialize
{
	JIT_LOG_INFO("Initializing JIT Manager for iOS 26...");

	// Priority 1: Debugger (StikDebug/Xcode)
	if([self isDebuggerAttached])
	{
		JIT_LOG_INFO("Debugger detected - JIT enabled");
		[self setJITEnabled:YES withMethod:JITMethodDebugger status:@"JIT enabled via debugger"];
		return YES;
	}

	// Priority 2: Dual Mapping (iOS 26)
	if([self isDualMappingAvailable])
	{
		JIT_LOG_INFO("Dual mapping available - JIT enabled");
		[self setJITEnabled:YES withMethod:JITMethodDualMapping status:@"JIT enabled via dual mapping"];
		return YES;
	}

	// Priority 3: AltServer
	if([self isAltServerJITEnabled])
	{
		JIT_LOG_INFO("AltServer JIT enabled");
		[self setJITEnabled:YES withMethod:JITMethodAltServer status:@"JIT enabled via AltServer"];
		return YES;
	}

	JIT_LOG_ERROR("No JIT method available");
	[self setJITEnabled:NO withMethod:JITMethodNone status:@"No JIT available"];
	return NO;
}

- (BOOL)recheckAvailability
{
	JIT_LOG_INFO("Re-checking JIT availability...");
	return [self initialize];
}

#pragma mark - Detection Methods

- (BOOL)isDebuggerAttached
{
	int mib[4];
	struct kinfo_proc info;
	size_t size = sizeof(info);

	info.kp_proc.p_flag = 0;
	mib[0] = CTL_KERN;
	mib[1] = KERN_PROC;
	mib[2] = KERN_PROC_PID;
	mib[3] = getpid();

	if(sysctl(mib, 4, &info, &size, NULL, 0) == -1)
	{
		return NO;
	}

	return ((info.kp_proc.p_flag & P_TRACED) != 0);
}

- (BOOL)isDualMappingAvailable
{
	DualMappingManager* manager = [DualMappingManager sharedManager];
	return [manager checkJITAvailability];
}

- (BOOL)isAltServerJITEnabled
{
	void* testMem = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
	                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if(testMem != MAP_FAILED)
	{
		munmap(testMem, 4096);
		return YES;
	}

	return NO;
}

- (void)tryEnableViaAltServer
{
	JIT_LOG_INFO("Attempting to enable JIT via AltServer...");

	_status = JITStatusPending;
	_statusDescription = @"Connecting to AltServer...";

	[[NSNotificationCenter defaultCenter] postNotificationName:JITStatusDidChangeNotification object:self];

	[[AltServerJitService sharedService] enableJitWithCompletionHandler:^(BOOL success, NSError* error) {
	  dispatch_async(dispatch_get_main_queue(), ^{
		if(success)
		{
			[self setJITEnabled:YES withMethod:JITMethodAltServer status:@"JIT enabled via AltServer"];
		}
		else
		{
			NSString* errorMsg = error.localizedDescription ?: @"Unknown error";
			[self setJITEnabled:NO withMethod:JITMethodNone status:[NSString stringWithFormat:@"AltServer failed: %@", errorMsg]];
		}
	  });
	}];
}

#pragma mark - State Management

- (void)setJITEnabled:(BOOL)enabled withMethod:(JITMethod)method status:(NSString*)status
{
	_isJITEnabled = enabled;
	_activeMethod = method;
	_status = enabled ? JITStatusAvailable : JITStatusUnavailable;
	_statusDescription = status;

	switch(method)
	{
	case JITMethodDebugger:
		_methodName = @"Debugger";
		break;
	case JITMethodDualMapping:
		_methodName = @"Dual Mapping";
		break;
	case JITMethodAltServer:
		_methodName = @"AltServer";
		break;
	default:
		_methodName = @"None";
		break;
	}

	[[NSNotificationCenter defaultCenter] postNotificationName:JITStatusDidChangeNotification object:self];
}

#pragma mark - Diagnostics

- (NSDictionary<NSString*, id>*)diagnosticInfo
{
	DualMappingManager* dualManager = [DualMappingManager sharedManager];

	return @{
		@"status" : @(_status),
		@"activeMethod" : @(_activeMethod),
		@"methodName" : _methodName ?: @"",
		@"isJITEnabled" : @(_isJITEnabled),
		@"statusDescription" : _statusDescription ?: @"",
		@"debuggerAttached" : @([self isDebuggerAttached]),
		@"dualMappingInfo" : [dualManager diagnosticInfo] ?: @{},
		@"deviceModel" : [[UIDevice currentDevice] model],
		@"systemVersion" : [[UIDevice currentDevice] systemVersion]
	};
}

@end
