//
//  DualMapping.h
//  Play
//
//  iOS 26 JIT - Dual Mapping for W^X bypass
//

#ifndef DualMapping_h
#define DualMapping_h

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

@interface DualMappedRegion : NSObject

@property(nonatomic, readonly) void* rwAddress;
@property(nonatomic, readonly) void* rxAddress;
@property(nonatomic, readonly) size_t size;
@property(nonatomic, readonly) BOOL isValid;

- (nullable instancetype)initWithSize:(size_t)size;
- (BOOL)writeData:(const void*)data length:(size_t)length atOffset:(size_t)offset;
- (void*)executableAddressForWritableAddress:(void*)rwAddr;
- (void)invalidateCacheAtOffset:(size_t)offset length:(size_t)length;
- (void)unmap;

@end

@interface DualMappingManager : NSObject

@property(class, readonly, strong) DualMappingManager* sharedManager;
@property(nonatomic, readonly) BOOL isJITAvailable;
@property(nonatomic, readonly, copy) NSString* statusMessage;

- (BOOL)checkJITAvailability;
- (nullable DualMappedRegion*)allocateRegionWithSize:(size_t)size;
- (void)releaseRegion:(DualMappedRegion*)region;
- (NSDictionary<NSString*, id>*)diagnosticInfo;

@end

NS_ASSUME_NONNULL_END

#endif /* DualMapping_h */
