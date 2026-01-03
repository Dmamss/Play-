//
//  iOSJitService.h
//  Play
//
//  iOS 26 JIT Support with dual mapping
//  Includes legacy API for AppDelegate.mm compatibility
//

#ifndef iOSJitService_h
#define iOSJitService_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface iOSJitService : NSObject

/// Shared singleton instance (NEW API)
@property(class, readonly, strong) iOSJitService* sharedService;

/// Shared singleton instance (LEGACY API)
@property(class, readonly, strong) iOSJitService* sharedInstance;

/// Whether JIT is currently available (NEW API)
@property(nonatomic, readonly) BOOL isJITAvailable;

/// Whether JIT is currently available (LEGACY API)
@property(nonatomic, readonly) BOOL isJitAvailable;

/// Status message for UI display
@property(nonatomic, readonly, copy) NSString* statusMessage;

/// Initialize the JIT service (NEW API)
- (BOOL)initialize;

/// Start the JIT service (LEGACY API)
- (BOOL)startJitService;

/// Allocate executable memory for JIT code
- (void* _Nullable)allocateExecutableMemory:(size_t)size;

/// Write code to JIT memory region
- (BOOL)writeCode:(const void*)code length:(size_t)length toAddress:(void*)destination;

/// Get executable address for a writable address
- (void* _Nullable)executableAddressFor:(void*)writableAddress;

/// Free previously allocated JIT memory
- (void)freeExecutableMemory:(void*)address;

/// Invalidate instruction cache for given range
- (void)invalidateInstructionCache:(void*)address length:(size_t)length;

@end

NS_ASSUME_NONNULL_END

#endif /* iOSJitService_h */
