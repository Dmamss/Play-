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

@end

NS_ASSUME_NONNULL_END
