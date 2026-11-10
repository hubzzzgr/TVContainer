#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TVInstaller : NSObject
+ (NSURL *)applicationsURL;
+ (BOOL)hasCertificate;
+ (BOOL)importCertificate:(NSData *)data password:(NSString *)password error:(NSError **)error;
+ (BOOL)removeCertificateWithError:(NSError **)error;
+ (void)installArchive:(NSURL *)archive completion:(void (^)(NSError * _Nullable error))completion;
+ (void)launchApp:(NSString *)folder completion:(void (^)(NSError * _Nullable error))completion;
+ (BOOL)removeApp:(NSString *)folder error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
