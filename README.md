# Azure DevOps Assessment

[![Tests](https://github.com/accentient/ado-assessment/actions/workflows/tests.yml/badge.svg)](https://github.com/accentient/ado-assessment/actions/workflows/tests.yml)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4)](#supported-versions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A PowerShell tool that produces a high-level assessment of an [Azure DevOps](https://azure.microsoft.com/products/devops)
organization: every project's process, teams, people, security groups, work items, repositories,
pipelines, feeds, wikis, and more, in one Markdown report and one JSON file.

It is built for the first week of an engagement, when you need to know what is actually in an
organization before anyone starts changing it: ahead of a migration, a process redesign, a
licensing review, or a coaching engagement.

> **Azure DevOps is only ever read from.** Every REST call goes through a single function,
> `Invoke-AdoGet`, that hard codes `-Method Get`, so the tool has no code path that can modify
> anything in the organization. A PAT with only Read scopes is enough. See
> [How read-only is enforced](#how-read-only-is-enforced) to check this for yourself.

## Features

- Assesses **every project in the organization**, a list of named projects, or the projects in a
  CSV file.
- **Expands nested groups** to count distinct people, service principals, and service accounts, so
  "114 people" means 114 identities, not 114 group memberships.
- Resolves each person's **roles** (Project Admin, Contributor, Reader), **teams**, other group
  memberships, **access level**, and **last access** date.
- Counts work items **per type per project**, including custom types from inherited processes, and
  rolls them up into a cross-project matrix.
- Reports repository size, branch count, last commit and author, and flags disabled and empty repos.
- Separates **YAML and classic** pipelines, flags paused and disabled ones, and shows last run and
  result.
- Writes **Markdown for people and JSON for tools**. The JSON holds everything the report shows, plus
  the descriptors and ids behind it.
- Degrades gracefully: an area the token cannot read is reported as `n/a` with a warning, and the
  rest of the assessment continues.

## What gets assessed

| Area                  | Detail                                                                           |
| --------------------- | -------------------------------------------------------------------------------- |
| Project               | Process (and parent, for inherited processes), source control, visibility, state, description, last activity |
| Teams                 | Members, team admins, default team, role mix                                     |
| Security groups       | Distinct people, nested groups, groups that could not be expanded                |
| People                | Email, kind, roles, teams, other groups, access level, last access               |
| Work items            | Count per type, total, last change, area and iteration path counts               |
| Git repositories      | Default branch, branches, size, last commit and author, disabled, empty          |
| Build pipelines       | Folder, YAML or classic, status, repository, last run and result                 |
| Release pipelines     | Classic release definitions                                                      |
| Artifacts             | Feeds, package counts, protocols, upstream sources                               |
| Other                 | Wikis, test plans, service connections, agent pools available                    |

The report opens with an organization summary table. Each project then gets its own section: the
project details, an *At a glance* table of counts, then Teams, Security groups, People, Work item
types, Git repositories, Build and Release pipelines, Artifact feeds, Service connections, and any
Warnings. The report closes with a work item type matrix across all projects.

Contributors and Readers are the members of the project's built-in groups of those names, after
expanding nested groups. A person in both counts in both.

## Supported versions

| Platform                  | Status                                                                  |
| ------------------------- | ----------------------------------------------------------------------- |
| **Azure DevOps Services** | **Supported**                                                           |
| Azure DevOps Server       | Not supported. The script builds `dev.azure.com` service URLs.          |

Any process works: Basic, Agile, Scrum, CMMI, and inherited processes built on them. Work item types
are read from each project's process rather than assumed.

The script runs on **Windows**, in Windows PowerShell 5.1 or PowerShell 7. PowerShell 7 is faster.
Windows is required because the PAT is read from Windows Credential Manager.

## Getting started

### Prerequisites

- Windows, with [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
  (recommended) or Windows PowerShell 5.1
- An Azure DevOps **PAT** with the read scopes below

No modules need to be installed.

### Token scopes

Create the PAT as a custom-defined token and tick **Read** only for each of these. Nothing in the
tool needs write access, and a token with write scopes should not be used for it.

| Scope (Read)                  | Used for                                                                                   | If missing                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------- |
| Agent Pools                   | Agent queues available to the project                                                      | Agent pools omitted                          |
| Analytics                     | Work item counts per type and last change date                                             | Counts show `n/a`; types still listed        |
| Build                         | Build pipeline definitions, YAML or classic, latest run                                    | Pipelines show `n/a`                         |
| Code                          | Git repositories, default branch, size, branch count, last commit, TFVC detection          | Repos show `n/a`                             |
| Graph                         | Security groups, nested group expansion, team rosters, display names and emails            | Teams and People sections show `n/a`         |
| Member Entitlement Management | Access level (Basic, Stakeholder, Visual Studio) and last access date                      | Access level columns omitted from People     |
| Packaging                     | Artifact feeds scoped to the project and their package counts                              | Feeds show `n/a`                             |
| Project and Team              | Project list, description, process, visibility, teams, team members, area and iteration paths | Run cannot start                          |
| Release                       | Classic release pipeline definitions                                                       | Releases show `n/a`                          |
| Service Connections           | Service connection names and types                                                         | Service connections omitted                  |
| Test Management               | Test plans                                                                                 | Test plans omitted                           |
| Wiki                          | Wikis                                                                                      | Wikis omitted                                |
| Work Items                    | Work item types, process list (to show inherited process parents)                          | Work item types show `n/a`                   |

The PAT dialog lists scopes alphabetically, the same order as this table. Set the token's
organization to the one being assessed.

A missing scope does not stop the run, except for Project and Team. The affected area reads `n/a`,
and the report's Warnings section names what could not be read and why.

### Who should own the token

A PAT can never do more than the account that created it.

- For a complete assessment, use a token owned by a **Project Collection Administrator**. Otherwise
  the owner must be a member of every project being assessed, or the project is reported as "not
  found or not visible".
- **Analytics** refuses Stakeholder accounts with *VS403527: Access to data from the Analytics OData
  endpoint is not available for all users*. The owner needs Basic or higher, plus the *View
  analytics* project permission that Readers and Contributors have by default.
- **Test plans** refuse accounts without a Test Plans license with *TF400409: You do not have
  licensing rights to access this feature*. The owner needs Basic + Test Plans or a Visual Studio
  Enterprise subscription. Everything else in the report is unaffected.

When a request is refused, the warning in the console and in the report includes the server's own
message, so you can tell a scope problem from a license problem.

### Store the PAT

The PAT is never stored in the repository. It lives in Windows Credential Manager as a generic
credential, and the script reads it at run time, so you are not prompted on each run. Use one entry
per organization, for example `contoso-assessment-PAT`.

The easiest way is to let the script prompt for it. In `Main`, set `$script:AdoCredentialName`,
uncomment `Save-AdoPat`, and run the script once. The token is read as a secure string and is never
echoed or written to disk in clear text. Comment `Save-AdoPat` out again afterwards. `Remove-AdoPat`
deletes the entry.

To add it by hand instead:

1. Open **Credential Manager** from the Start menu (also under Control Panel, User Accounts).
2. Select **Windows Credentials**, then **Add a generic credential**.
3. Set **Internet or network address** to the credential name, **User name** to `pat`, and
   **Password** to the PAT. The user name is only a label.

The address must match `$script:AdoCredentialName` exactly, including case. You can also use
`cmdkey /generic:contoso-assessment-PAT /user:pat /pass:<PAT>`, but that leaves the token in your
shell history.

### Configure and run

The script takes no parameters. `Main`, at the top of
[`src/AssessProjects.ps1`](src/AssessProjects.ps1), is the control panel: edit it, then run the
script.

1. Set the organization URL and credential name:

   ```powershell
   $script:AdoOrgUrl = "https://dev.azure.com/contoso/"
   $script:AdoCredentialName = "contoso-assessment-PAT"
   ```

   `https://contoso.visualstudio.com/` URLs work too.

2. Optionally uncomment `Test-AdoConnection` and run the script to confirm the token works and see
   which projects it can reach.

3. Choose which projects to assess:

   ```powershell
   $script:Assessment = AssessProjects -All                                  # every project
   $script:Assessment = AssessProjects -Projects 'Project A', 'Project B'    # just these
   $script:Assessment = AssessProjects -CsvPath (Join-Path (Split-Path $PSScriptRoot -Parent) "projects.csv")
   ```

   Add `-OutputPath <file.md>` to any of them to choose where the report goes.

4. Run it:

   ```powershell
   .\src\AssessProjects.ps1
   ```

Pressing F5 in VS Code runs the file the same way. The results stay in `$Assessment` after the run
so you can explore them in the terminal, for example `$Assessment[0].Security.Teams`.

The CSV can be a plain list, one project name per line. A header row named `Project`, `Name`, or
`ProjectName` is skipped, as are blank lines and lines starting with `#`. Names on one line separated
by commas also work. `projects.csv` in the repository root is gitignored.

### Output

Each run writes to `reports/` in the repository root:

| File                                    | Holds                                          |
| --------------------------------------- | ---------------------------------------------- |
| `ADO-Assessment-<yyyyMMdd-HHmm>.md`     | The report                                     |
| `ADO-Assessment-<yyyyMMdd-HHmm>.json`   | Everything behind the report, machine-readable |

Progress and warnings are written to the console. There is no separate log file.

## Handle the output with care

The report lists **names, email addresses, group memberships, access levels, and last access
dates** for everyone in the organization. Treat it as you would any other personnel data:

- `reports/` is gitignored. Keep it that way.
- Share reports only with people entitled to see who has access to what.
- Scrub before attaching a report to a GitHub issue. [CONTRIBUTING.md](CONTRIBUTING.md) says what
  to send instead.

## How read-only is enforced

- `Invoke-AdoGet` is the only function that calls `Invoke-WebRequest`, and it passes `-Method Get`
  unconditionally. Nothing else in the file touches the network.
- No endpoint used by the script needs a request body. Work item counts come from the Analytics
  OData service rather than WIQL, which would need a `POST`.
- Identities are resolved with the Graph `users` and `groups` `GET` endpoints, not the
  `subjectlookup` batch endpoint, which is also a `POST`.
- The only things the script writes are the report files on your local disk and, if you use
  `Save-AdoPat`, an entry in your own Windows Credential Manager.

You can confirm the first point yourself:

```powershell
Select-String -Path .\src\AssessProjects.ps1 -Pattern 'Invoke-RestMethod|Invoke-WebRequest'
```

It finds two calls, both inside `Invoke-AdoGet` and both passing `-Method Get` (the second is a
one-time retry with a preview API version). The only other match is a comment.

The test suite checks all of this automatically, on every push.

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

The suite needs [Pester](https://pester.dev) 5 or later, and no PAT: it never touches Azure DevOps
or Windows Credential Manager. Tests like this are called **hermetic**. It has three layers:

- **Read-only guarantee.** The script's syntax tree is checked to confirm that only
  `Invoke-AdoGet` makes web requests, that every one passes `-Method Get` with no body, and that
  `Main` ships with placeholder settings. At run time, every request the HTTP layer sends is
  checked to be a GET.
- **Unit tests** for paging, error handling, nested group expansion, and the report formatting
  helpers, with the web request replaced by a mock.
- **End-to-end tests** that run a full assessment against a small fake organization
  ([`tests/FakeAdo.ps1`](tests/FakeAdo.ps1)). It has one healthy project and one the token can only
  partly read, and the tests check the report and the JSON that come out.

As a safety net, the tests replace `Invoke-WebRequest`, `Invoke-RestMethod`, and the credential
functions with versions that throw. A code path no test has mocked fails instead of reaching the
network. The suite runs in both PowerShell 7 and Windows PowerShell 5.1 on every push and pull
request.

## Limitations

- A point-in-time snapshot. There is no trend or comparison between runs.
- Inventory, not judgment. The report shows what is there. It does not score it or recommend
  changes.
- People are counted per project. Someone in four projects appears in each project's table, and the
  organization total is not deduplicated.
- Groups sourced from Entra ID are expanded only as far as Azure DevOps has materialized them.
  Anything it cannot expand is listed under *Not expanded*, so treat that count as a floor.
- Service principals Azure DevOps cannot resolve to a display name are shown by descriptor.
- Branch counts are not available for disabled repositories.
- TFVC repositories are detected but not assessed.
- Package counts stop at 1,000 per feed.
- Analytics can lag live data by a few minutes.
- Large organizations take a while: expanding every group and team costs one Graph call per group
  plus one per nested group, so a project with many teams can take a minute or two.

## Assessment consulting

An assessment report is the starting point, not the finding. Deciding what the numbers mean for
your teams, your process, and your plans is usually the hard part. If you would like help with an
Azure DevOps assessment, migration, or Professional Scrum adoption, get in touch.

**Richard Hundhausen** · <richard@accentient.com> · [Accentient](https://accentient.com)

## Contributing

Bug reports and pull requests are welcome through
[GitHub Issues](https://github.com/accentient/ado-assessment/issues). When reporting a problem,
please include the Warnings section of the report and the console output around the failure.
**Never send a token, and never send an unscrubbed report.**

See [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules for changes. Everyone taking part is
expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md), not through
public issues.

## Related

- [digitalai-agility-to-ado](https://github.com/accentient/digitalai-agility-to-ado): migrate work
  items from Digital.ai Agility (formerly VersionOne) into Azure DevOps.

## License

[MIT](LICENSE)
