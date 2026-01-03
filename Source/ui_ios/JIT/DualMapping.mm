//
//  DualMapping.mm
//  Play
//
//  iOS 26 JIT - Dual Mapping Implementation
//  Uses dlsym to load pthread_jit_write_protect_np
//

#import "DualMapping.h"
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <os/log.h>
#import <pthread.h>
#import <sys/mman.h>

static os_log_t GetDualMappingLog(void)
{
	static os_log_t log = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  log = os_log_create("com.virtualapplications.play", "DualMapping");
	});
	return log;
}

#define DM_LOG_INFO(fmt, ...) os_log_info(GetDualMappingLog(), fmt, ##__VA_ARGS__)
#define DM_LOG_ERROR(fmt, ...) os_log_error(GetDualMappingLog(), fmt, ##__VA_ARGS__)
#define DM_LOG_DEBUG(fmt, ...) os_log_debug(GetDualMappingLog(), fmt, ##__VA_ARGS__)

// Dynamic lookup for pthread_jit_write_protect_np
typedef void (*pthread_jit_write_protect_np_t)(int);
static pthread_jit_write_protect_np_t g_pthread_jit_write_protect_np = NULL;
static BOOL g_jit_write_protect_checked = NO;

static void InitJITWriteProtect(void)
{
	if(!g_jit_write_protect_checked)
	{
		g_pthread_jit_write_protect_np = (pthread_jit_write_protect_np_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
		g_jit_write_protect_checked = YES;
		if(g_pthread_jit_write_protect_np)
		{
			DM_LOG_INFO("pthread_jit_write_protect_np found via dlsym");
		}
	}
}

static void SetJITWriteProtection(BOOL protect)
{
	InitJITWriteProtect();
	if(g_pthread_jit_write_protect_np)
	{
		g_pthread_jit_write_protect_np(protect ? 1 : 0);
	}
}

static BOOL IsJITWriteProtectAvailable(void)
{
	InitJITWriteProtect();
	return g_pthread_jit_write_protect_np != NULL;
}

#pragma mark - DualMappedRegion

@interface DualMappedRegion ()
@property(nonatomic, readwrite) void* rwAddress;
@property(nonatomic, readwrite) void* rxAddress;
@property(nonatomic, readwrite) size_t size;
@property(nonatomic, readwrite) BOOL isValid;
@property(nonatomic, assign) mach_port_t memoryPort;
@property(nonatomic, assign) BOOL usesPthreadJIT;
@end

@implementation DualMappedRegion

- (nullable instancetype)initWithSize:(size_t)requestedSize
{
	self = [super init];
	if(!self) return nil;

	vm_size_t pageSize = vm_page_size;
	size_t alignedSize = (requestedSize + pageSize - 1) & ~(pageSize - 1);

	_size = alignedSize;
	_isValid = NO;
	_memoryPort = MACH_PORT_NULL;
	_usesPthreadJIT = NO;

	DM_LOG_INFO("Allocating dual-mapped region: requested=%zu, aligned=%zu", requestedSize, alignedSize);

	if([self tryMapJIT:alignedSize])
	{
		DM_LOG_INFO("Dual mapping created using MAP_JIT");
		return self;
	}

	if([self tryMachMemoryEntry:alignedSize])
	{
		DM_LOG_INFO("Dual mapping created using mach_make_memory_entry");
		return self;
	}

	DM_LOG_ERROR("Failed to create dual mapping");
	return nil;
}

- (BOOL)tryMapJIT:(size_t)size
{
#ifdef MAP_JIT
	if(!IsJITWriteProtectAvailable())
	{
		DM_LOG_DEBUG("pthread_jit_write_protect_np not available, skipping MAP_JIT");
		return NO;
	}

	void* addr = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
	                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);

	if(addr == MAP_FAILED)
	{
		DM_LOG_DEBUG("MAP_JIT mmap failed: %s", strerror(errno));
		return NO;
	}

	_rwAddress = addr;
	_rxAddress = addr;
	_usesPthreadJIT = YES;
	_isValid = YES;

	return YES;
#else
	return NO;
#endif
}

- (BOOL)tryMachMemoryEntry:(size_t)size
{
	kern_return_t kr;
	mach_port_t task = mach_task_self();

	vm_address_t rwAddr = 0;
	kr = vm_allocate(task, &rwAddr, size, VM_FLAGS_ANYWHERE);
	if(kr != KERN_SUCCESS)
	{
		DM_LOG_DEBUG("vm_allocate for RW failed: %d", kr);
		return NO;
	}

	memory_object_size_t entrySize = size;
	mach_port_t memEntry = MACH_PORT_NULL;
	kr = mach_make_memory_entry_64(task, &entrySize, rwAddr,
	                               VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE,
	                               &memEntry, MACH_PORT_NULL);
	if(kr != KERN_SUCCESS)
	{
		DM_LOG_DEBUG("mach_make_memory_entry_64 failed: %d", kr);
		vm_deallocate(task, rwAddr, size);
		return NO;
	}

	vm_address_t rxAddr = 0;
	kr = vm_map(task, &rxAddr, size, 0, VM_FLAGS_ANYWHERE,
	            memEntry, 0, FALSE, VM_PROT_READ | VM_PROT_EXECUTE,
	            VM_PROT_READ | VM_PROT_EXECUTE, VM_INHERIT_NONE);
	if(kr != KERN_SUCCESS)
	{
		DM_LOG_DEBUG("vm_map for RX failed: %d", kr);
		mach_port_deallocate(task, memEntry);
		vm_deallocate(task, rwAddr, size);
		return NO;
	}

	_rwAddress = (void*)rwAddr;
	_rxAddress = (void*)rxAddr;
	_memoryPort = memEntry;
	_usesPthreadJIT = NO;
	_isValid = YES;

	return YES;
}

- (BOOL)writeData:(const void*)data length:(size_t)length atOffset:(size_t)offset
{
	if(!_isValid || !data) return NO;
	if(offset + length > _size)
	{
		DM_LOG_ERROR("Write exceeds bounds");
		return NO;
	}

	if(_usesPthreadJIT)
	{
		SetJITWriteProtection(NO);
	}

	memcpy((uint8_t*)_rwAddress + offset, data, length);

	if(_usesPthreadJIT)
	{
		SetJITWriteProtection(YES);
	}

	[self invalidateCacheAtOffset:offset length:length];
	return YES;
}

- (void*)executableAddressForWritableAddress:(void*)rwAddr
{
	if(!_isValid) return NULL;

	ptrdiff_t offset = (uint8_t*)rwAddr - (uint8_t*)_rwAddress;
	if(offset < 0 || (size_t)offset >= _size) return NULL;

	return (uint8_t*)_rxAddress + offset;
}

- (void)invalidateCacheAtOffset:(size_t)offset length:(size_t)length
{
	if(!_isValid) return;
	void* start = (uint8_t*)_rxAddress + offset;
	sys_icache_invalidate(start, length);
}

- (void)unmap
{
	if(!_isValid) return;

	mach_port_t task = mach_task_self();

	if(_rwAddress == _rxAddress)
	{
		munmap(_rwAddress, _size);
	}
	else
	{
		vm_deallocate(task, (vm_address_t)_rwAddress, _size);
		vm_deallocate(task, (vm_address_t)_rxAddress, _size);
	}

	if(_memoryPort != MACH_PORT_NULL)
	{
		mach_port_deallocate(task, _memoryPort);
	}

	_rwAddress = NULL;
	_rxAddress = NULL;
	_memoryPort = MACH_PORT_NULL;
	_isValid = NO;
}

- (void)dealloc
{
	[self unmap];
}

@end

#pragma mark - DualMappingManager

@interface DualMappingManager ()
@property(nonatomic, readwrite) BOOL isJITAvailable;
@property(nonatomic, readwrite, copy) NSString* statusMessage;
@property(nonatomic, strong) NSMutableSet<DualMappedRegion*>* activeRegions;
@property(nonatomic, strong) dispatch_queue_t managerQueue;
@end

@implementation DualMappingManager

+ (DualMappingManager*)sharedManager
{
	static DualMappingManager* instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	  instance = [[DualMappingManager alloc] init];
	});
	return instance;
}

- (instancetype)init
{
	self = [super init];
	if(self)
	{
		_isJITAvailable = NO;
		_statusMessage = @"Not checked";
		_activeRegions = [NSMutableSet set];
		_managerQueue = dispatch_queue_create("com.virtualapplications.play.dualmapping", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (BOOL)checkJITAvailability
{
	DM_LOG_INFO("Checking dual mapping JIT availability...");

	DualMappedRegion* testRegion = [[DualMappedRegion alloc] initWithSize:vm_page_size];

	if(testRegion && testRegion.isValid)
	{
		uint32_t testCode[] = {0xD65F03C0}; // ARM64 RET

		if([testRegion writeData:testCode length:sizeof(testCode) atOffset:0])
		{
			_isJITAvailable = YES;
			_statusMessage = @"Dual mapping available (iOS 26 compatible)";
			DM_LOG_INFO("%{public}@", _statusMessage);
		}
		else
		{
			_isJITAvailable = NO;
			_statusMessage = @"Dual mapping write failed";
			DM_LOG_ERROR("%{public}@", _statusMessage);
		}

		[testRegion unmap];
	}
	else
	{
		_isJITAvailable = NO;
		_statusMessage = @"Dual mapping not available";
		DM_LOG_ERROR("%{public}@", _statusMessage);
	}

	return _isJITAvailable;
}

- (nullable DualMappedRegion*)allocateRegionWithSize:(size_t)size
{
	if(!_isJITAvailable)
	{
		DM_LOG_ERROR("Cannot allocate - JIT not available");
		return nil;
	}

	DualMappedRegion* region = [[DualMappedRegion alloc] initWithSize:size];

	if(region && region.isValid)
	{
		dispatch_sync(_managerQueue, ^{
		  [self.activeRegions addObject:region];
		});
		DM_LOG_INFO("Allocated region: size=%zu", size);
	}

	return region;
}

- (void)releaseRegion:(DualMappedRegion*)region
{
	if(!region) return;

	dispatch_sync(_managerQueue, ^{
	  [self.activeRegions removeObject:region];
	});

	[region unmap];
}

- (NSDictionary<NSString*, id>*)diagnosticInfo
{
	return @{
		@"dualMappingAvailable" : @(_isJITAvailable),
		@"statusMessage" : _statusMessage ?: @"",
		@"activeRegions" : @(_activeRegions.count),
		@"pageSize" : @(vm_page_size),
		@"pthreadJitWriteProtectAvailable" : @(IsJITWriteProtectAvailable())
	};
}

@end
