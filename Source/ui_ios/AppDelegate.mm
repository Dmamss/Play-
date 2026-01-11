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
	StikDebugJitService* jitService = [StikDebugJitService sharedService];
	[jitService registerPreferences];

	// Set TXM environment variable for CodeGen
	if([jitService hasTXM])
	{
		setenv("PLAY_HAS_TXM", "1", 1);
		NSLog(@"[AppDelegate] TXM mode enabled for CodeGen");
	}

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
