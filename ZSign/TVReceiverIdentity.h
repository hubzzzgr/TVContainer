#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// In-memory PKCS#12 for local TLS only. Never written to the filesystem.
@interface TVReceiverIdentity : NSObject
+ (NSData * _Nullable)createForDevice:(NSString *)deviceName password:(NSString *)password error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(create(deviceName:password:));
@end
NS_ASSUME_NONNULL_END
