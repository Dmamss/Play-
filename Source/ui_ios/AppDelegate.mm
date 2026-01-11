#import "AppDelegate.h"
#import "EmulatorViewController.h"
#include "../gs/GSH_OpenGL/GSH_OpenGL.h"
#include "DebuggerSimulator.h"
#import "StikDebugJitService.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
	// Initialize StikDebug JIT service for iOS 26+
	[[StikDebugJitService sharedService] registerPreferences];

	[EmulatorViewController registerPreferences];
	CGSH_OpenGL::RegisterPreferences();
	return YES;
}

- (BOOL)application:(UIApplication*)app openURL:(NSURL*)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id>*)options
{
	// Handle play-jit:// URL scheme callback from StikDebug
	if([url.scheme isEqualToString:@"play-jit"])
	{
		NSLog(@"[AppDelegate] Received StikDebug callback: %@", url);
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
