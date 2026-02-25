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

	// NOTE: Do NOT allocate JIT memory here for TXM devices!
	// CS_DEBUGGED flag being set does NOT mean StikDebug is actively listening for breakpoints.
	// StikDebug may have attached briefly to set the flag, then stopped monitoring.
	// Wait for StikDebug callback (play://jit-enabled) before calling BreakGetJITMapping.
	// Only non-TXM devices (iOS 26+ without A15+) can safely allocate early.
	if([jitService isJitActive] && ![JITInitializer requiresTXM])
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
