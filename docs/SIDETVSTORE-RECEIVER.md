# SideTVStore / TVContainer transfer protocol 1

This is the shared contract for the SideTVStore sender. The receiver lives in
TVContainer; SideTVStore must implement the TLS handshake below before sending
the existing upload frames. There is no plaintext TCP fallback and no shared
developer signing identity used for transport encryption.

## Direct connection and lifetime

TVContainer runs a direct TCP TLS listener without Bonjour service publication.
It does not configure `NWListener.Service`, declare `_tvcontainer._tcp`, or depend
on discovery/publication succeeding. It does not advertise another service type.

In SideTVStore, pair/select the TV in the Apple TV tab, open Settings → TVContainer,
choose that saved TV, enter the current port displayed by TVContainer, and connect.
SideTVStore uses its existing Apple TV pairing discovery to find the chosen TV's
address within a short window, then falls back to the saved pairing address.
No developer tunnel, installation service, or new developer pairing is required.
Addresses and friendly names are routing/display hints, including when stale;
the independent TLS certificate pin authenticates the receiver. Existing developer
pairing does not authorize transfer pairing. Phone-side editable port preferences
belong to the selected saved TV UUID, so duplicate names cannot share routing state.
Save a valid port submitted with Connect even if connecting fails. Changing a
transfer destination must not change SideTVStore's My Apps library destination.

TVContainer persists its enabled preference (off initially) and last successfully
bound TCP port. First use selects an ephemeral port; later starts request the saved
port. Only `NWListener.ready` with an actual bound port updates the displayed port
and saved preference. Failure never shows a requested/stale port as a bound port.
Settings offers Change TCP Port (1–65535) and explicit Use Automatic Port recovery.
A busy/unavailable saved port produces a clear error; there is no silent fallback.
After a change, copy the newly displayed port into SideTVStore's editable field.
Changing the port closes existing connections and preserves TLS/signing identities.

Keep both devices on the same reachable local network, with Local Network access
granted in the actual iPhone host, including a LiveContainer-hosted SideTVStore.
Removing the custom Bonjour declaration does not bypass local-network privacy.
The launcher must remain open with the receiver enabled. Disabling or actual
backgrounding closes the listener and all connections. Native TV keyboard
presentation does not stop it. Launching a guest replaces the launcher process.
No background keep-alive, port scanning, rendezvous server, or extra handshake
listener is used.

Settings shows separate listener and SideTVStore connection indicators. The latter
is green only while at least one connection has completed mutual TLS; opening TCP
or presenting an unapproved certificate cannot light it. One upload uses one
connection, so it clears after completion, disconnect, disable, or backgrounding.
A previously paired phone is not necessarily currently connected.

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
   first compare/approve the TV fingerprint on iPhone, allowing its server-trust
   callback to finish; then compare/approve the phone fingerprint on Apple TV.
   Waiting for the TV Pair popup before allowing the phone's server verification
   can deadlock the handshake. Pin the approved TV only after TLS reaches ready.
   Do not silently accept every server certificate.
   Use a custom `sec_protocol_options_set_verify_block` for the self-signed
   certificate; match the approved pin rather than the IP, saved TV UUID, or CN.
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
differs between Apple and OpenSSL). P12 passwords never belong in discovery, request headers, preferences,
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
The import dialog contains a secure password field on **Apple TV**. SideTVStore's
current-certificate export is passwordless after explicit phone consent: leave
that field empty. Other valid P12s may require a password. The password is not
sent by SideTVStore; it is validated using the
existing developer identity importer and stored only in the encrypted Keychain.
The password dialog allows 180 seconds for remote entry; other confirmations
expire after 60 seconds. Certificate-validation diagnostics are suppressed.
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
certificate storage under concurrent writers. Direct connections run without
Bonjour configuration. Port checks cover persisted reuse, occupied-port failure
without saving/displaying a false bind, explicit automatic recovery, a selected
port, unchanged TLS identity, and the authenticated connection indicator. The
normal standalone archive compiles tvOS UI and Security/Network integration.

Physical Apple TV / LiveContainer-hosted SideTVStore validation remains required:
paired-TV address routing with Local Network allowed/denied; two saved TVs with
duplicate names and independent persisted ports; restart/port/IP changes and
stale-address failures; first approval/saved-pin reconnect/changed-pin rejection
and Forget Paired Devices; remote confirmation/password entry; real provisioned
IPA/P12 import results, early errors, cancellation, existing-certificate refusal,
and disconnect after approval. Loopback/build success does not establish physical
compatibility. Never publish private IPA, certificate, password, or pairing fixtures.
