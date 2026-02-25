//
//  StikDebugJitService.h
//  Play! iOS - iOS 26 JIT Support via StikDebug
//
//  Provides JIT activation for all iOS 26+ devices (iPhone 12/A14 through latest).
//  Both TXM (A15+) and non-TXM (A14 etc.) devices require StikDebug on iOS 26.
//  Works alongside existing AltServerJitService.
//

#import <UIKit/UIKit.h>

@interface StikDebugJitService : NSObject

/// Shared singleton instance
+ (StikDebugJitService*)sharedService;

/// Register preferences for settings UI
- (void)registerPreferences;

/// Check if device has TXM (A15+/M2+ chips)
- (BOOL)hasTXM;

/// Check if JIT is currently available (pre-iOS 26, or debugger attached on iOS 26+)
- (BOOL)isJitAvailable;

/// Check if JIT is currently active (alias for isJitAvailable)
- (BOOL)isJitActive;

/// Check if StikDebug activation is needed (all devices on iOS 26+)
- (BOOL)needsActivation;

/// Check if StikDebug app is installed on the device
- (BOOL)isStikDebugInstalled;

/// Set environment variables needed for JIT operation
- (void)setEnvironmentForJIT;

/// Handle callback URL from StikDebug app
/// @param url The callback URL to handle
/// @return YES if the URL was handled
- (BOOL)handleCallbackURL:(NSURL*)url;

/// Request JIT activation via StikDebug app
/// @param completion Called with success status
- (void)requestActivation:(void (^)(BOOL success))completion;

/// Request JIT activation via StikDebug app (with error reporting)
/// @param completion Called with success status and optional error
- (void)requestActivationWithCompletion:(void (^)(BOOL success, NSError* error))completion;

/// Detach StikDebug debugger (call after all JIT allocations)
- (void)detachDebugger;

/// JIT enabled status (read-only)
@property(nonatomic, readonly) BOOL jitEnabled;

/// TXM active status (read-only)
@property(nonatomic, readonly) BOOL txmActive;

/// iOS version (read-only)
@property(nonatomic, readonly) float iosVersion;

@end
