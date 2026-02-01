#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JITInitializer : NSObject

/// Detects the appropriate JIT mode and configures CodeGen (does NOT allocate memory yet)
+ (void)initializeJITSystem;

/// Allocates the executable memory region (call AFTER StikDebug has attached for LuckTXM mode)
+ (void)allocateExecutableMemoryIfNeeded;

@end

NS_ASSUME_NONNULL_END
