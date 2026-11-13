# Offline registry value input

The offline record editor can replace REG_EXPAND_SZ with literal text and
REG_MULTI_SZ with a list of nonempty lines. An empty editor represents an empty
list; empty items, embedded NUL and line breaks within an item cannot be
represented by this input. Use raw hexadecimal for those bytes. Text is
validated before replacement, with the Registry.pol size limit enforced.
Environment variables are not expanded. Policy commands use raw input only.

Friendly input is an explicit replacement, not an automatic conversion of
existing bytes. Closing or cancelling it leaves the raw data unchanged. The
record editor also offers an explicit raw-data option for nonstandard values:
it validates the Registry.pol record structure but does not assert that the
typed payload is valid. This option does not apply the record to a domain.
If the draft or selected side changes while the editor is open, its result is
discarded.
