# SideTVStore / TVContainer transfer protocol 1

This is the shared contract for the SideTVStore sender. The receiver lives in
TVContainer; SideTVStore must implement the TLS handshake below before sending
the existing upload frames. There is no plaintext TCP fallback and no shared
developer signing identity used for transport encryption.

## Discovery and lifetime

Browse `_tvcontainer._tcp` over Bonjour. Resolve the service's actual TCP port;
never hard-code a port. TXT records contain the actual Apple TV `deviceName`,
TVContainer `appVersion`, and `protocol=1`. Names and discovery records are hints,
not authentication. The TLS certificate fingerprint is the identity.

Settings persists the enabled preference (off initially). The listener and its
Bonjour advertisement start when TVContainer's launcher is active and enabled.
Disabling, leaving the launcher, or backgrounding closes the listener and its
connections. Relaunching a guest replaces this launcher process as before.

## Pairing: mutual TLS 1.3 and certificate pins

1. Each app generates its own persistent self-signed RSA-2048/SHA-256 TLS identity
   (PKCS#12 supported); the certificate has digitalSignature/keyEncipherment key
   usage and serverAuth/clientAuth extended key usage. Private identities belong
   in the device Keychain. They are unrelated to the developer's P12 certificate.
2. SideTVStore opens an `NWConnection` using `NWProtocolTLS.Options`, TLS 1.3
   minimum, and its client identity set with
   `sec_protocol_options_set_local_identity`. TVContainer requires a client
   certificate, verifies its signature/validity, and requires proof of possession
   through the TLS handshake. Session tickets and resumption are disabled.
3. On the first connection, BOTH devices show the SHA-256 fingerprint of each
   leaf certificate's **DER bytes** (64 uppercase hex characters). The user must
   compare both fingerprints, then approve on Apple TV and approve/pin the TV
   certificate in SideTVStore. Do not silently accept every server certificate.
   Use a custom `sec_protocol_options_set_verify_block` for the self-signed
   certificate; match the approved pin rather than the IP, Bonjour name, or CN.
   Certificate CN can be the device's friendly name for display only.
4. Apple TV's native Pair/Cancel prompt expires after 60 seconds. A known
   certificate skips that prompt on subsequent handshakes. A new/changed
   certificate requires fresh confirmation. SideTVStore must reject a changed
   saved TV pin until the user explicitly repeats pairing. Uploads cannot begin
   until the TLS connection is ready.
5. The TV's fingerprint is also shown in Settings. Forget Paired Devices removes
   the saved client pins and closes active connections; it does not remove the
   signing certificate or rotate the TV identity. Each phone identity is paired
   separately, with at most 16 client pins stored on Apple TV.

Apple TV holds its TLS identity and approved client pins in a separate Keychain
service. Its local identity container uses a random nonempty wrapping password
kept only inside that encrypted Keychain value (empty-password PKCS#12 derivation
differs between Apple and OpenSSL). P12 passwords never belong in Bonjour, request headers, preferences,
logs, URLs, or pairing messages.

## Upload framing (inside TLS)

One upload per connection. No application-layer pairing header is added.

```
uint32_be JSON_header_byte_length
UTF-8 JSON header
exactly header.size binary bytes
```

```
{"version":1,"action":"uploadIPA","filename":"Example.ipa","size":123}
{"version":1,"action":"uploadP12","filename":"Signing.p12","size":123}
```

The four-byte length counts UTF-8 bytes, not characters. Header length is
1–16384 bytes. Size is a positive integer: at most 2 GiB for IPA and 4 MiB for
P12. Filename must be a basename with no path separators or control characters,
and at most 200 UTF-8 bytes. The action chooses the importer; actual contents,
rather than the filename extension, determine validity. Unknown version/actions,
malformed JSON, truncated files and idle connections fail. TCP packet boundaries
are irrelevant. The payload is streamed in chunks of at most 64 KiB to private,
protected temporary storage. A transfer can last at most 30 minutes and cannot
remain idle for more than 30 seconds per read.

The response is a four-byte big-endian JSON byte length followed by UTF-8 JSON:

```
{"ok":true,"message":"App installed in TVContainer."}
{"ok":false,"message":"Installation cancelled on Apple TV."}
```

SideTVStore should monitor responses while writing, because malformed headers,
busy state, missing signing identity, or an existing certificate can be rejected
before the payload is read. A successful file write alone is **not** an install
result. Wait for the complete JSON response. After any response the connection
closes. For an uncertain connection failure after confirmation, don't report
success or blindly retry: the native installer may already have committed.

## Native confirmation and result

For IPA, TVContainer extracts the app name from Info.plist and shows Install /
Cancel. The existing platform, Mach-O, signing and guest installation checks run
on confirmation. The response reports that installer's actual success/failure.

For P12, a certificate already installed causes rejection without replacement.
The import dialog contains a secure password field on **Apple TV** (empty is
allowed). The password is not sent by SideTVStore; it is validated using the
existing developer identity importer and stored only in the encrypted Keychain.
The final write uses atomic `SecItemAdd`, never `SecItemUpdate`, so a concurrent
import cannot replace an existing identity. Wrong-password/invalid/team-mismatch
results are failures. Temporary files are removed on success, cancellation,
malformed input, disconnect, timeout and disable. Stale receiver staging is also
removed on a subsequent start when no confirmed install still uses it.

Once installation is confirmed, disabling or disconnecting stops network access
but allows the native installer to finish safely; it retains its source until
completion and then removes it. Each incoming transfer owns the library's busy
state, preventing overlapping URL and receiver installs/imports.

## Validation

`tests/test_receiver.sh` uses real loopback Network.framework mutual TLS and
test-only Keychain namespaces: framing and limits, split/coalesced frames,
pairing approval/rejection, client-certificate requirements, plaintext rejection,
persistent trust/identity, importer result propagation, certificate-present
policy, interrupted/disabled transfers, temporary-file cleanup, and atomic
certificate storage under concurrent writers. The normal standalone archive
compiles tvOS UI, Bonjour declarations and Security/Network integration.

Apple TV / SideTVStore physical discovery, fingerprint comparison, remote
confirmation/password entry, and provisioned IPA/P12 imports still require a
device test. Never publish private IPA, certificate, password, or pairing fixtures.
