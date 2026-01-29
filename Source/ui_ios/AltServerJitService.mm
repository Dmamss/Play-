#import "AltServerJitService.h"
#include "AppConfig.h"
#import "PreferenceDefs.h"

#if __has_include("AltKit-Swift.h")
#import "AltKit-Swift.h"
#define HAS_ALTKIT 1
#else
#define HAS_ALTKIT 0
#endif

@implementation AltServerJitService

- (id)init
{
	if(self = [super init])
	{
		[self registerPreferences];
	}
	return self;
}

+ (AltServerJitService*)sharedAltServerJitService
{
	static AltServerJitService* sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  sharedInstance = [[self alloc] init];
	});
	return sharedInstance;
}

- (void)registerPreferences
{
	CAppConfig::GetInstance().RegisterPreferenceBoolean(PREFERENCE_ALTSTORE_JIT_ENABLED, false);
}

- (void)startProcess
{
	//Don't start the process if it's not enabled
	if(!CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_ALTSTORE_JIT_ENABLED))
	{
		return;
	}

	//Don't start the process if we've already started it
	if(self.processStarted)
	{
		return;
	}

	self.processStarted = YES;

#if HAS_ALTKIT
	[[ALTServerManager sharedManager] startDiscovering];

	[[ALTServerManager sharedManager] autoconnectWithCompletionHandler:^(ALTServerConnection* connection, NSError* error) {
	  if(error)
	  {
		  return NSLog(@"Could not auto-connect to server. %@", error);
	  }

	  [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError* error) {
		if(success)
		{
			NSLog(@"Successfully enabled JIT compilation!");
			[[ALTServerManager sharedManager] stopDiscovering];
			self.jitEnabled = true;
		}
		else
		{
			NSLog(@"Could not enable JIT compilation. %@", error);
		}

		[connection disconnect];
	  }];
	}];
#else
	NSLog(@"AltKit not available - AltServer JIT path disabled");
#endif
}

@end
