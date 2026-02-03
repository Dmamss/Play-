#import "AppDelegate.h"
#import "EmulatorViewController.h"
#import "JITInitializer.h"
#include "../gs/GSH_OpenGL/GSH_OpenGL.h"
#include "DebuggerSimulator.h"
#import "StikDebugJitService.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
	// StikDebugJitService initializes automatically via its singleton init
	StikDebugJitService* jitService = [StikDebugJitService sharedService];

	if([jitService isJitActive])
	{
		[jitService setEnvironmentForJIT];
	}

	// Initialize CodeGen JIT system with appropriate mode based on iOS version and TXM status
	[JITInitializer initializeJITSystem];

	// Start async JIT memory allocation as early as possible (if debugger already attached).
	// On TXM devices (A15+), BreakGetJITMapping triggers a brk #0xf00d trap that blocks
	// the calling thread — running it async prevents UI freezing.
	if([jitService isJitActive])
	{
		[JITInitializer beginAsyncAllocation];
	}

	[EmulatorViewController registerPreferences];
	CGSH_OpenGL::RegisterPreferences();
	return YES;
}

- (BOOL)application:(UIApplication*)app openURL:(NSURL*)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id>*)options
{
	// Handle StikDebug callback
	if([[StikDebugJitService sharedService] handleCallbackURL:url])
	{
		return YES;
	}

	return NO;
}

- (void)applicationWillResignActive:(UIApplication*)application
{
}

- (void)applicationDidEnterBackground:(UIApplication*)application
{
}

- (void)applicationWillEnterForeground:(UIApplication*)application
{
}

- (void)applicationDidBecomeActive:(UIApplication*)application
{
}

- (void)applicationWillTerminate:(UIApplication*)application
{
	StopSimulateDebugger();
}

@end
