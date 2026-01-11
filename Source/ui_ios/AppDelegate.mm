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
	// Initialize StikDebug JIT service
	[[StikDebugJitService sharedService] registerPreferences];

	[EmulatorViewController registerPreferences];
	CGSH_OpenGL::RegisterPreferences();
	return YES;
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
