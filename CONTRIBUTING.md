# Contributing

Thanks for your interest in improving the Azure DevOps Assessment. Bug reports, fixes, and new
assessment areas are all welcome.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Found a security problem?** Do not open an issue. Follow [SECURITY.md](SECURITY.md) instead.
- **Planning something larger than a small fix?** Open an issue first so we can agree on the approach
  before you spend time on it.

## Reporting a bug

Open a [bug report](https://github.com/accentient/ado-assessment/issues/new/choose) and include:

- Your PowerShell version (`$PSVersionTable.PSVersion`)
- The **Warnings** section of the report
- The console output around the failure

**Never include a token, and never attach an unscrubbed report.** Reports and console output contain
names, email addresses, group memberships, and access levels. Replace them with placeholders before
posting anything.

## Development setup

1. Use Windows with [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
   or Windows PowerShell 5.1. Changes must work in both.
2. Install Pester 5 or later:

   ```powershell
   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
   ```

3. Fork the repository, clone your fork, and create a branch from `main`.

## Running the tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

The suite is **hermetic**: nothing resolves a credential, reaches Azure DevOps, or writes outside
Pester's TestDrive. Keep it that way:

- Mock at the HTTP boundary. Unit tests mock `Invoke-WebRequest` or `Invoke-AdoGet`. End-to-end
  tests use the fake organization in `tests/FakeAdo.ps1`.
- If you call a new endpoint, add a route for it to `tests/FakeAdo.ps1`. The end-to-end tests fail
  on any request the fake organization does not know.
- Use synthetic data only (`contoso`, `@contoso.example`), never names, emails, or ids from a real
  organization.

The same suite runs in GitHub Actions, in both PowerShell 7 and Windows PowerShell 5.1, on every
push and pull request.

## Trying a change against a real organization

The tests cover behavior, but a run against a real organization is still the best check that a new
API is read correctly. Follow the README to store a PAT and set `Main` to point at a test
organization you own. Do not commit those settings: `Main` must keep its `YOUR-ORG` placeholders,
and a test checks that it does.

## Ground rules for changes

- **Read only, always.** Every REST call goes through `Invoke-AdoGet`, which hard codes
  `-Method Get`. Do not add another code path to Azure DevOps, and do not add write scopes to the
  documented token scopes. Pull requests that could modify an organization will not be merged.
- **Degrade gracefully.** If an area cannot be read, report it as `n/a`, add a warning, and let the
  rest of the assessment continue. `Invoke-Collector` does this for you.
- **Markdown and JSON stay in step.** Anything new in the report also belongs in the JSON output.
- **No secrets or personal data in the repo.** Not in code, docs, screenshots, or commit messages.
  `reports/` and `projects.csv` are gitignored for this reason.
- **Match the surrounding code.** Follow the naming, comment density, and idiom already in the file.
- **Document what users will see.** Update the README in the same pull request, including the token
  scopes table if you call a new API.

## Submitting a pull request

1. Keep the pull request focused on one change.
2. Add or update tests for the behavior you changed, and make sure the full suite passes.
3. Fill in the pull request template, including how you verified the change.
4. Make sure nothing in the diff identifies a real organization or person.

A maintainer will review and may ask for changes. Thanks for helping.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
