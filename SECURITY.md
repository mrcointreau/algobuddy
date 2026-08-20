# Security

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** button under the Security tab, which opens a private advisory. Please don't open a public issue for anything that looks exploitable.

## Threat model

This section is unusually short, and that is the point.

### What algobuddy has access to

**No credentials.** There are no tokens, no keys, no passwords. There is no credential store because there is nothing to store.

**No node access.** algobuddy never connects to your Algorand node, over SSH, a tunnel, a VPN, or an exposed endpoint. It cannot leak node credentials because it is never given any, and it cannot affect your node's operation because it never reaches it.

**No signing.** It holds no spending key, constructs no transaction, and submits nothing to the network. Nothing it does can move funds or change your account's participation state.

**One public address.** The only thing you give it is an Algorand address, which is public information already recorded on chain.

### What it talks to

Exactly two hosts, both configurable in Settings:

- an algod endpoint, for `/v2/accounts`, `/v2/ledger/supply` and `/v2/blocks`
- an indexer endpoint, for `/v2/block-headers`

No telemetry, no analytics, no crash reporting, and no third-party SDKs. The `dependencies` array in `Package.swift` is empty, so there is no supply chain beyond the Swift toolchain itself.

### The one privacy trade

By default those endpoints are a public API provider. That provider can see which address you watch and how often you poll. This is stated in the Settings pane rather than buried here, and both URLs are editable, so anyone who minds can point algobuddy at an algod they control.

### Verifying it

The app is distributed as source and built on your machine. Everything above is checkable rather than promised:

```bash
grep -rn "URLSession\|http" Sources/   # every network call
cat Package.swift                      # empty dependencies array
```

## Distribution

Releases are built from source (`make install`). The build ad-hoc signs the app, which does not satisfy Gatekeeper but produces a valid signature that macOS expects. There is currently no Developer ID signature and no notarization: a paid Apple Developer Program membership is required for both, and building from source does not need one.

Because you compile it yourself, the binary you run is the source you can read. Notarization would prove Apple scanned a binary for known malware. It would not tell you what the binary does with your data. Reading the source does.

One practical consequence of the ad-hoc signature: its identity is the hash of the binary, so every rebuild is a new identity to anything keyed on code signing. After updating with `make install`, macOS may treat the app as new and ask for notification permission again, and a login item registration may need re-ticking in Settings.

## Supported versions

Only the latest commit on `main`. This is a small tool with a single contributor; there are no backported fixes.
