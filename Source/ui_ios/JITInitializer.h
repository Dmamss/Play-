#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification posted when JIT memory allocation completes (on any thread)
extern NSNotificationName const JITMemoryReadyNotification;

@interface JITInitializer : NSObject

/// Detects the appropriate JIT mode and configures CodeGen (does NOT allocate memory yet)
+ (void)initializeJITSystem;

/// Allocates the executable memory region synchronously (call AFTER StikDebug has attached for LuckTXM mode)
+ (void)allocateExecutableMemoryIfNeeded;

/// Begins asynchronous JIT memory allocation on a background thread.
/// Posts JITMemoryReadyNotification when complete.
+ (void)beginAsyncAllocation;

/// Returns YES if JIT memory has been allocated and is ready for use.
+ (BOOL)isReady;

/// Blocks the calling thread until JIT memory is ready, or timeout expires.
/// @param timeout Maximum seconds to wait. 0 = no wait (just check).
/// @return YES if ready, NO if timed out.
+ (BOOL)waitForReadiness:(NSTimeInterval)timeout;

/// Returns YES if this device requires TXM (A15+/M2+ on iOS 26+)
+ (BOOL)requiresTXM;

/// Returns YES if JIT is available and working (StikDebug attached on TXM devices)
/// Call this AFTER waitForReadiness to check if emulation can proceed.
+ (BOOL)isJITAvailable;

/// Returns a user-friendly error message if JIT is not available, or nil if OK.
+ (nullable NSString*)jitUnavailableReason;

/// Returns YES if debugger (StikDebug) is currently attached.
+ (BOOL)isDebuggerAttached;

/// Wait for debugger (StikDebug) to attach, then allocate JIT memory.
/// @param timeout Maximum seconds to wait for debugger
/// @param progressBlock Called periodically with progress updates (0.0-1.0)
/// @return YES if JIT was successfully enabled
+ (BOOL)waitForJITWithTimeout:(NSTimeInterval)timeout
                progressBlock:(nullable void (^)(float progress, NSString* status))progressBlock;

@end

NS_ASSUME_NONNULL_END
