# Seal parity spike

`SealParity` is an offline, dependency-free .NET 10 spike for reproducing the
repository's existing PowerShell seal bytes. It has no production wiring and
performs no model, provider, network, or write operation other than normal
build output.

The request is JSON on stdin (or `--request <path>`):

```json
{"contractVersion":"devpilot.seal-parity.v1","operation":"sha256","profile":"json-text-v1","value":{"b":2,"a":1}}
```

The response includes canonical text, canonical UTF-8 as base64, byte length,
and lowercase SHA-256. `hmac-sha256` additionally accepts a `key` and optional
ordered `domains`. `excludeRootProperties` models existing self-excluding
digest fields such as `manifestDigest`.

Input files are decoded as strict UTF-8. As in the production PowerShell
`ReadAllText` paths, a leading UTF-8 BOM is consumed and output is BOM-free.

The versioned details and supported production surfaces are frozen in
`seal-parity-contract.v1.json`. Run the PowerShell/C# cross-verification with:

```powershell
./tools/Test-SealParity.ps1
```
