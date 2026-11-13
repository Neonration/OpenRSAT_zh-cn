# Registry policy record details

The domain settings viewer and the local offline draft use the same read-only
record details. The draft keeps double-click for editing and provides a
separate View record button.

DWORD, big-endian DWORD and QWORD values show unsigned decimal and hexadecimal.
REG_SZ, REG_EXPAND_SZ and REG_MULTI_SZ require properly terminated UTF-16,
including valid surrogate pairs and no embedded empty items. An empty MULTI_SZ
uses two NUL units. Invalid data is reported without repairing it; environment
variables are never expanded. Policy commands, REG_LINK and unknown types are
shown as raw data and are not executed or opened.

Text previews are limited to 4096 UTF-16 units. Details always show the byte
length and complete hexadecimal bytes allowed by the Registry.pol size limit.
Displaying a record does not alter its bytes or apply policy.
