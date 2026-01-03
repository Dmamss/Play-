//
//  iOSJitService.mm
//  Play
//
//  iOS 26 JIT Support with dual mapping
//

#import "iOSJitService.h"
#import "JIT/DualMapping.h"
#import "JIT/JITManager.h"
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <os/log.h>

static os_log_t GetServiceLog(void)
{
	static os_log_t log = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  log = os_log_create("com.virtualapplications.play", "JITService");
	});
	return log;
}

#define SVC_LOG_INFO(fmt, ...) os_log_info(GetServiceLog(), fmt, ##__VA_ARGS__)
#define SVC_LOG_ERROR(fmt, ...) os_log_error(GetServiceLog(), fmt, ##__VA_ARGS__)

#pragma mark - Memory Region Tracker

@interface JITMemoryRegion : NSObject
@property(nonatomic, strong) DualMappedRegion* region;
@property(nonatomic, assign) size_t currentOffset;
@end

@implementation JITMemoryRegion
@end

#pragma mark - iOSJitService Implementation

@interface iOSJitService ()
@property(nonatomic, readwrite) BOOL isJITAvailable;
@property(nonatomic, readwrite, copy) NSString* statusMessage;
@property(nonatomic, strong) NSMutableDictionary<NSValue*, JITMemoryRegion*>* memoryRegions;
@property(nonatomic, strong) dispatch_queue_t serviceQueue;
@end

@implementation iOSJitService

#pragma mark - Singleton

+ (iOSJitService*)sharedService
{
	static iOSJitService* instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  instance = [[iOSJitService alloc] init];
	});
	return instance;
}

+ (iOSJitService*)sharedInstance
{
	return [self sharedService];
}

- (instancetype)init
{
	self = [super init];
	if(self)
	{
		_isJITAvailable = NO;
		_statusMessage = @"JIT service not initialized";
		_memoryRegions = [NSMutableDictionary dictionary];
		_serviceQueue = dispatch_queue_create("com.virtualapplications.play.jitservice", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

#pragma mark - Legacy API

- (BOOL)isJitAvailable
{
	return self.isJITAvailable;
}

- (BOOL)startJitService
{
	return [self initialize];
}

#pragma mark - Initialization

- (BOOL)initialize
{
	SVC_LOG_INFO("Initializing iOS JIT Service...");

	JITManager* jitManager = [JITManager sharedManager];
	BOOL available = [jitManager initialize];

	_isJITAvailable = available;
	_statusMessage = jitManager.statusDescription;

	if(available)
	{
		SVC_LOG_INFO("JIT Service initialized successfully");
	}
	else
	{
		SVC_LOG_ERROR("JIT Service initialization failed: %{public}@", _statusMessage);
	}

	return available;
}

#pragma mark - Memory Management

- (void*)allocateExecutableMemory:(size_t)size
{
	if(!_isJITAvailable)
	{
		SVC_LOG_ERROR("Cannot allocate - JIT not available");
		return NULL;
	}

	__block void* result = NULL;

	dispatch_sync(_serviceQueue, ^{
	  DualMappingManager* manager = [DualMappingManager sharedManager];
	  DualMappedRegion* region = [manager allocateRegionWithSize:size];

	  if(region && region.isValid)
	  {
		  JITMemoryRegion* memRegion = [[JITMemoryRegion alloc] init];
		  memRegion.region = region;
		  memRegion.currentOffset = 0;

		  NSValue* key = [NSValue valueWithPointer:region.rwAddress];
		  self.memoryRegions[key] = memRegion;

		  result = region.rwAddress;
		  SVC_LOG_INFO("Allocated JIT memory: %zu bytes at %p", size, result);
	  }
	});

	return result;
}

- (BOOL)writeCode:(const void*)code length:(size_t)length toAddress:(void*)destination
{
	if(!code || !destination) return NO;

	__block BOOL success = NO;

	dispatch_sync(_serviceQueue, ^{
	  for(NSValue* key in self.memoryRegions)
	  {
		  JITMemoryRegion* memRegion = self.memoryRegions[key];
		  DualMappedRegion* region = memRegion.region;

		  void* rwBase = region.rwAddress;
		  void* rwEnd = (uint8_t*)rwBase + region.size;

		  if(destination >= rwBase && destination < rwEnd)
		  {
			  size_t offset = (uint8_t*)destination - (uint8_t*)rwBase;
			  success = [region writeData:code length:length atOffset:offset];
			  return;
		  }
	  }

	  SVC_LOG_ERROR("Address %p not found in any JIT region", destination);
	});

	return success;
}

- (void*)executableAddressFor:(void*)writableAddress
{
	if(!writableAddress) return NULL;

	__block void* result = NULL;

	dispatch_sync(_serviceQueue, ^{
	  for(NSValue* key in self.memoryRegions)
	  {
		  JITMemoryRegion* memRegion = self.memoryRegions[key];
		  DualMappedRegion* region = memRegion.region;

		  void* rwBase = region.rwAddress;
		  void* rwEnd = (uint8_t*)rwBase + region.size;

		  if(writableAddress >= rwBase && writableAddress < rwEnd)
		  {
			  result = [region executableAddressForWritableAddress:writableAddress];
			  return;
		  }
	  }
	});

	return result;
}

- (void)freeExecutableMemory:(void*)address
{
	if(!address) return;

	dispatch_sync(_serviceQueue, ^{
	  NSValue* keyToRemove = nil;

	  for(NSValue* key in self.memoryRegions)
	  {
		  JITMemoryRegion* memRegion = self.memoryRegions[key];
		  if(memRegion.region.rwAddress == address)
		  {
			  [[DualMappingManager sharedManager] releaseRegion:memRegion.region];
			  keyToRemove = key;
			  break;
		  }
	  }

	  if(keyToRemove)
	  {
		  [self.memoryRegions removeObjectForKey:keyToRemove];
		  SVC_LOG_INFO("Freed JIT memory at %p", address);
	  }
	});
}

- (void)invalidateInstructionCache:(void*)address length:(size_t)length
{
	if(!address || length == 0) return;

	dispatch_sync(_serviceQueue, ^{
	  for(NSValue* key in self.memoryRegions)
	  {
		  JITMemoryRegion* memRegion = self.memoryRegions[key];
		  DualMappedRegion* region = memRegion.region;

		  void* rwBase = region.rwAddress;
		  void* rwEnd = (uint8_t*)rwBase + region.size;

		  if(address >= rwBase && address < rwEnd)
		  {
			  size_t offset = (uint8_t*)address - (uint8_t*)rwBase;
			  [region invalidateCacheAtOffset:offset length:length];
			  return;
		  }
	  }

	  sys_icache_invalidate(address, length);
	});
}

- (void)dealloc
{
	dispatch_sync(_serviceQueue, ^{
	  for(NSValue* key in self.memoryRegions)
	  {
		  JITMemoryRegion* memRegion = self.memoryRegions[key];
		  [[DualMappingManager sharedManager] releaseRegion:memRegion.region];
	  }
	  [self.memoryRegions removeAllObjects];
	});
}

@end
