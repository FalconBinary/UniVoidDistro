# The channels' public keys

One directory per channel, `stable/` and `rolling/`, each with the public key xbps trusts for
that channel, in the file `FINGERPRINT.plist` that `xbps-install` itself writes. `pkg/keygen.sh`
makes them; the private keys are never here (docs/uni/rolling.md, "The keys").
