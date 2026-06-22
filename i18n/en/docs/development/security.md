# Security policy

## Core principle

The security policy is determined by the client, not the provider.

**The provider can:**
- pass metadata;
- appearance hints;
- advisory settings.

**The provider cannot:**
- weaken client security;
- enforce behavior through headers.

## Android security

- TUN is forced on
- Split tunneling from the profile takes priority
- The update loader verifies SHA256 checksums
- Built-in nodes cannot set local addresses and ports
- `olcrtc` only works in CNC mode
- `byedpi` only tests the specified URLs

## Provider headers

- `flclashm-*` headers remain advisory
- Appearance cannot change runtime security
