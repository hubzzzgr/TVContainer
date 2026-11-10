#import <Foundation/Foundation.h>

// The same cache root is used by the installer and the pre-UIKit bootstrap.
NSURL *TVStorageRoot(void);
NSDictionary *TVReadSigningIdentity(void);
BOOL TVSaveSigningIdentity(NSData *certificate, NSString *password, NSError **error);
BOOL TVRemoveSigningIdentity(NSError **error);
void TVCaptureRelaunchContext(int argc, char *argv[]);
BOOL TVRelaunch(void (^completion)(NSError *error));
