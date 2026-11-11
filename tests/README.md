# OpenRSAT test suite

OpenRSAT test suite objective's is to define the behavior of a feature. 
Each feature in the project has an objective: create a group object, move a user object, delegate rights... and testing each feature ensure is does what it says.
To do so, tests must be implemented alongside a feature developement, and a new bug requires a new test to define the expected behavior before fixing the feature.

## Tests structure

OpenRSAT test suite contains different kind of tests:
- **`unit`**: Ensures the reliability of logical functions. Does not require external dependency.
- **`integration`**: Ensures the reliability of network calls. Requires an Active Directory to run.
- **`gui`**: Ensures the reliability of the user interface's behavior. Requires a Desktop Environement to run.

## Batch operations and multi-controller deletion

After registering the dependencies described in [build.zh-cn.md](../build.zh-cn.md), build and run the new offline tests from the repository root:

```powershell
lazbuild --build-mode=test tests\openrsattests.lpi
.\tests\openrsattests.exe --test TUnitTestDNOperations
.\tests\openrsattests.exe --test TUnitTestModuleADUCOption
.\tests\openrsattests.exe --test TUnitTestComputerDelete
```

On 2026-11-11, these tests passed under Free Pascal 3.2.2 on Windows 64-bit with 61 assertions and no failures:

| Test class | Assertions | Coverage |
| --- | ---: | --- |
| `TUnitTestDNOperations` | 23 | Chinese names, escaped DN separators, target validation |
| `TUnitTestModuleADUCOption` | 8 | Disabled default, save/reopen, preserving scope when disabled |
| `TUnitTestComputerDelete` | 30 | Controller allowlist, deduplication, GUID identity, rejecting DC accounts |

These commands do not connect to Active Directory. They do not verify real LDAP deletion, replication, delegated permissions or TLS/Kerberos authentication. Integration tests require a dedicated AD test domain and are not included in this result. Run only the named classes above when an AD environment has not been configured.

GUI checks and Windows compilation are separate from these unit assertions. No automated daily test run is configured by this change.
