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
.\tests\openrsattests.exe --test TUnitTestDoubleListLogic
.\tests\openrsattests.exe --test TUnitTestRSATOption
```

After merging upstream 0.4.594, these tests passed on 2026-11-11 under Free Pascal 3.2.2 on Windows 64-bit with 91 assertions and no failures:

| Test class | Assertions | Coverage |
| --- | ---: | --- |
| `TUnitTestDNOperations` | 32 | Chinese names, escaped DN separators, target validation, overlapping parent/child ordering |
| `TUnitTestModuleADUCOption` | 8 | Disabled default, save/reopen, preserving scope when disabled |
| `TUnitTestComputerDelete` | 30 | Controller allowlist, deduplication, GUID identity, rejecting DC accounts |
| `TUnitTestDoubleListLogic` | 13 | Upstream dual-list selection behavior |
| `TUnitTestRSATOption` | 8 | System language default, language save/reopen including Chinese aliases, preserving other settings |

These commands do not connect to Active Directory. They do not verify real LDAP deletion, replication, delegated permissions or TLS/Kerberos authentication. Integration tests require a dedicated AD test domain and are not included in this result. Run only the named classes above when an AD environment has not been configured.

GUI checks and Windows compilation are separate from these unit assertions. No automated daily test run is configured by this change.

The merged win64 executable was also launched offline: the Chinese main window, Simplified Chinese language option, and multi-controller settings were displayed correctly. Enabling the multi-controller option enabled its host list. Restarting with a saved `zh` configuration loaded Chinese. Clicking through language selection and saving in the modal dialog was not verified end to end; persistence is covered by the tests above.

## Review regression tests

The default console suite is offline. Integration tests are registered only when
the `INTEGRATION` compiler define is explicitly enabled. With the dependencies
registered, run the console suite, GUI suite, and packaging contract tests:

```powershell
lazbuild --build-mode=test tests\openrsattests.lpi
.\tests\openrsattests.exe --noenter
lazbuild tests\gui\openrsattestsgui.lpi
.\tests\gui\openrsattestsgui.exe --noenter
python -B -m unittest discover -s tests/packaging -v
```

The new console tests cover LDAP TLS policy at connection time, password-reset
cancellation and failure, atomic multi-value modifications and retries, DNS
binary payloads, and mixed advanced-search operators and escaping. GUI tests
cover unsaved options across page changes, profile port round trips, invalidating
every search window on disconnect or reconnect, and retaining property edits
after a failed save. The GUI suite needs a desktop environment.

Packaging tests use mock `dpkg-deb` and `rpmbuild` tools. They check that the local
binary and language catalogs are copied without downloads, reject missing or
invalid inputs, normalize Windows line endings in staged RPM specs and DEB
maintainer scripts, and verify cleanup on failure. They require Bash (Git Bash
is supported on Windows); they do not build or install real Linux packages.

These offline tests do not perform real AD mutations or TLS handshakes. In
particular, recursive Sites and Services deletion still needs an isolated AD
test domain for end-to-end validation.
