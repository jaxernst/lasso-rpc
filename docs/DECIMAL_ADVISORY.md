# Decimal advisory range discrepancy

The locked Decimal 3.1.1 release is newer than the fixed 3.0.0 release identified in the [maintainer advisory](https://github.com/ericmj/decimal/security/advisories/GHSA-rhv4-8758-jx7v). On September 8, 2026, the [EEF record imported by OSV](https://osv.dev/vulnerability/EEF-CVE-2026-32686) states the same affected range in prose but omits the fixed boundary from its machine-readable range, causing `mix hex.audit` to flag 3.1.1.

The exception for CVE-2026-32686 is guarded by `DecimalSecurityTest`: the package must remain at the reviewed 3.1.1 version, parsing and casting extreme positive/negative exponents must reject them, and directly constructed extreme exponents must not expand into unbounded normal-format output. This does not permit the vulnerable behavior or change the locked dependency.

Remove the exception when the feed is corrected. Re-review it whenever Decimal changes.
