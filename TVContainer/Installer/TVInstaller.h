#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TVInstaller : NSObject
+ (NSURL *)applicationsURL;
+ (NSArray<NSString *> *)iconAssetNamesAtURL:(NSURL *)url NS_SWIFT_NAME(iconAssetNames(at:));
+ (BOOL)hasCertificate;
+ (BOOL)importCertificate:(NSData *)data password:(NSString *)password error:(NSError **)error;
+ (BOOL)removeCertificateWithError:(NSError **)error NS_SWIFT_NAME(removeCertificate());
+ (void)installArchive:(NSURL *)archive completion:(void (^)(NSError * _Nullable error))completion;
+ (void)launchApp:(NSString *)folder completion:(void (^)(NSError * _Nullable error))completion;
+ (BOOL)removeApp:(NSString *)folder error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
