# GPO unknown-result diagnostics

`ugpodiagnostic` compares independently supplied baseline, candidate and observed
values for each policy file, complete GPT.INI, GPC version, flags, LDAP extension
lists, LDAP security descriptor, USN and file metadata. A match compares the
reported state and exact bytes only. It does not establish that policy or security
descriptor bytes are valid, that a write succeeded, who performed it, or that it
was durable. It provides no authority to retry, roll back or write.

The comparison requires the same domain, DC, DN, path, policy name and nonzero
16-byte AD objectGUID, as well as the same live, revocable LDAP session token.
The token is checked before, during and after comparison. A session may still be
revoked immediately afterward; saved results are not live evidence and cannot
restore a detached draft's domain binding. Callers must provide distinct input
and output variables.

Each resource retains independent copies of its three values and its result:
baseline, candidate, both, other, or incomplete. Both preserves ambiguity when
the baseline and candidate are identical. Incomplete observations and known
third values may coexist: `Summary` remains incomplete and `HasOther` retains
the conflict. Missing is reserved for confirmed missing policy files; unreadable
and not collected are different states. There is no conclusion for a failed
identity, session, shape or size check.

Adapted file values retain their original read status and file observation;
extension values retain the returned/not-returned/unavailable status. These
details are evidence, not comparison keys: the match uses state and bytes. A
not-collected value has no read result, regardless of its default detail fields.

`GpoDiagnosticPlanValues` supplies the two policy files, GPT.INI and GPC version
from an internally consistent offline plan. It deliberately leaves flags,
extensions, LDAP security, USN and file metadata uncollected: the plan does not
specify their candidate values. A caller must obtain actual reference evidence
and construct complete expectations before those resources can be compared.

`GpoDiagnosticEvidenceValues` adapts the existing LDAP and guarded file evidence.
A missing LDAP extension attribute is unreadable, not confirmed absent; returned
extension values are length framed in their observed order. File metadata keeps
its kind, volume and file identifiers, attributes, timestamp and length-framed
security descriptor. A missing policy requires a successful leaf-absence result
and valid parent evidence. Interrupted file collection retains its target and
per-file attempted states, while `Captured` still means the complete collection
passed its existing checks. These records do not authenticate the evidence
provider, rule out concurrent changes or replace a fresh same-target read.

Values are capped at 16 MiB per resource and 128 MiB per comparison; adapters
also check their input sizes before copying. This node is a pure comparison and
evidence adapter. It is not connected to a write executor or a user interface,
and performs no LDAP or filesystem writes.
