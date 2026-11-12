"""Exercise production Keychain writes in a unique test-only namespace."""
from pathlib import Path
import uuid

source = Path('TVContainer/Runtime/TVPlatform.m').read_text()
source = source[source.index('static NSDictionary *identityQuery'):]
source = source.replace('com.kdt.tvcontainer.signing', 'org.tvcontainer.signing-test.' + str(uuid.uuid4()))
Path('build/signing_store.m').write_text('#import "TVPlatform.h"\n#import <Security/Security.h>\n' + source)
