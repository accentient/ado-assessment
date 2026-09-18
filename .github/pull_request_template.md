## Summary

<!-- What does this change, and why? Link the issue it addresses, e.g. "Fixes #12". -->

## Verification

<!-- How did you verify it? Tests added or updated, and any run against a test organization. -->

## Checklist

- [ ] `Invoke-Pester -Path tests` passes locally
- [ ] Tests are added or updated for the behavior that changed
- [ ] Any new endpoint has a route in `tests/FakeAdo.ps1`, with synthetic data only
- [ ] Works in both PowerShell 7 and Windows PowerShell 5.1
- [ ] Every REST call still goes through `Invoke-AdoGet`; nothing can modify an organization
- [ ] An unreadable area still shows `n/a` with a warning instead of stopping the run
- [ ] README is updated if users will see a difference, including token scopes for any new API
- [ ] The diff contains no token, and no real organization, names, or emails
