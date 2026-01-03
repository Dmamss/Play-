//
//  JITManager.h
//  Play
//
//  Unified JIT Manager - Debugger + DualMapping + AltServer
//

#ifndef JITManager_h
#define JITManager_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JITMethod) {
	JITMethodNone = 0,
	JITMethodDebugger,
	JITMethodDualMapping,
	JITMethodAltServer
};

typedef NS_ENUM(NSInteger, JITStatus) {
	JITStatusUnknown = 0,
	JITStatusAvailable,
	JITStatusUnavailable,
	JITStatusPending
};

extern NSNotificationName const JITStatusDidChangeNotification;

@interface JITManager : NSObject

@property(class, readonly, strong) JITManager* sharedManager;
@property(nonatomic, readonly) JITStatus status;
@property(nonatomic, readonly) JITMethod activeMethod;
@property(nonatomic, readonly) BOOL isJITEnabled;
@property(nonatomic, readonly, copy) NSString* statusDescription;
@property(nonatomic, readonly, copy) NSString* methodName;

- (BOOL)initialize;
- (BOOL)recheckAvailability;
- (BOOL)isDebuggerAttached;
- (BOOL)isDualMappingAvailable;
- (BOOL)isAltServerJITEnabled;
- (void)tryEnableViaAltServer;
- (NSDictionary<NSString*, id>*)diagnosticInfo;

@end

NS_ASSUME_NONNULL_END

#endif /* JITManager_h */
