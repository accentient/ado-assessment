# Azure DevOps Assessment

[![Tests](https://github.com/accentient/ado-assessment/actions/workflows/tests.yml/badge.svg)](https://github.com/accentient/ado-assessment/actions/workflows/tests.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A PowerShell tool that produces a high-level assessment of an [Azure DevOps](https://azure.microsoft.com/products/devops)
organization: every project's process, teams, people, security groups, work items, repositories,
pipelines, feeds, wikis, and more, in one Markdown report and one JSON file.

It is built for the first week of an engagement, when you need to know what is actually in an
organization before anyone starts changing it: ahead of a migration, a process redesign, a
licensing review, or a coaching engagement.

> **Azure DevOps is only ever read from.** Every REST call goes through a single function that hard
> codes `-Method Get`, so the tool has no code path that can modify anything in the organization.
> Tests assert this.

## Features

- Assesses **every project in the organization**, or a configured subset.
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
| Project               | Process, source control, visibility, state, description, last activity           |
| Teams                 | Members, team admins, default team, role mix                                     |
| Security groups       | Distinct people, nested groups, groups that could not be expanded                |
| People                | Kind, roles, teams, other groups, access level, last access                      |
| Work items            | Count per type, total, last change, area and iteration path counts               |
| Git repositories      | Default branch, branches, size, last commit and author, disabled, empty          |
| Build pipelines       | Folder, YAML or classic, status, repository, last run and result                 |
| Release pipelines     | Classic release definitions                                                      |
| Artifacts             | Feeds and package counts                                                         |
| Other                 | Wikis, test plans, service connections, agent pools available                    |

The report opens with an organization summary table, then a section per project, and closes with a
work item type matrix across all projects.

## Supported versions

| Platform                  | Status                                                                 |
| ------------------------- | ---------------------------------------------------------------------- |
| **Azure DevOps Services** | **Verified**                                                           |
| Azure DevOps Server       | Expected to work, not tested. Access level and last access are Services only. |

Any process works: Basic, Agile, Scrum, CMMI, and inherited processes built on them. Work item types
are read from each project's process rather than assumed.

## Getting started

### Prerequisites

- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) or later
- An Azure DevOps **PAT** with the read scopes below
- [CredentialManager](https://www.powershellgallery.com/packages/CredentialManager), if you store
  the token in Windows Credential Manager: `Install-Module CredentialManager -Scope CurrentUser`

### Token scopes

Every scope is **Read**. Nothing in the tool needs write access, and a token with write scopes
should not be used for it.

| Scope                          | Needed for                              |
| ------------------------------ | --------------------------------------- |
| Project and Team               | Projects, teams, team members           |
| Graph                          | Security groups, identities, nesting    |
| Member Entitlement Management  | Access level, last access               |
| Work Items                     | Types, counts, area and iteration paths |
| Analytics                      | Work item counts per type               |
| Code                           | Repositories, branches, commits         |
| Build                          | Pipelines and runs                      |
| Release                        | Classic release definitions             |
| Packaging                      | Feeds and packages                      |
| Test Management                | Test plans                              |
| Service Connections            | Service connections                     |
| Agent Pools                    | Agent queues                            |
| Wiki                           | Wikis                                   |

A missing scope does not stop the run. The affected column reads `n/a`, and the report's Warnings
section names what could not be read and why.

The token's owner sees only what they have permission to see. For a complete assessment, use a
token owned by a **Project Collection Administrator**, or at least a member of **Project Collection
Valid Users** with read access to every project.

### Configuration

`appsettings.json` is gitignored so your organization's details stay out of source control. Copy
the sample and fill in your values:

```
cp appsettings.sample.json appsettings.json
```

| File                      | Committed | Holds                                                         |
| ------------------------- | --------- | ------------------------------------------------------------- |
| `appsettings.sample.json` | Yes       | Placeholder organization URL and credential target.           |
| `appsettings.json`        | No        | Your organization URL, optional project list. **No tokens.**  |

The token is never stored in the repo. It resolves from an environment variable first, then Windows
Credential Manager:

| Token            | Environment variable | Credential Manager target                |
| ---------------- | -------------------- | ---------------------------------------- |
| Azure DevOps PAT | `ADO_PAT`            | the `AzureDevOps.CredentialTarget` value |

To store it in Windows Credential Manager from your own terminal (keeping it out of shell history):

```
Import-Module CredentialManager
$token = Read-Host "Token" -AsSecureString
New-StoredCredential -Target "ADO-YourOrg-Read-PAT" -UserName "pat" `
  -SecurePassword $token -Persist LocalMachine -Type Generic
```

### Usage

The script takes no parameters. `Main` is the control panel: edit the calls, then run it.

```
./src/Assess-AdoOrganization.ps1
```

```
# Assess                              # every project in the organization
# Assess -Projects Core, Portfolio    # just these projects
```

Each run writes to `reports/`:

| File                                    | Holds                                         |
| --------------------------------------- | --------------------------------------------- |
| `ADO-Assessment-<yyyyMMdd-HHmm>.md`     | The report                                    |
| `ADO-Assessment-<yyyyMMdd-HHmm>.json`   | Everything behind the report, machine-readable |

and a log to `logs/Assess-AdoOrganization-<yyyyMMdd-HHmmss>.log`.

See **[docs/sample-report.md](docs/sample-report.md)** for a complete report generated from a
synthetic organization.

## Handle the output with care

The report lists **names, email addresses, group memberships, access levels, and last access
dates** for everyone in the organization. Treat it as you would any other personnel data:

- `reports/` and `logs/` are gitignored. Keep them that way.
- Share reports only with people entitled to see who has access to what.
- Scrub before attaching a report to a GitHub issue. The Contributing section below says what to
  send instead.

## Tests

```
Invoke-Pester -Path tests -Output Detailed
```

The suite is hermetic: nothing resolves a credential, queries a live organization, or writes a log
file, so it runs anywhere. It also runs on every push and pull request (see the badge above).

## Limitations

- A point-in-time snapshot. There is no trend or comparison between runs.
- Inventory, not judgment. The report shows what is there. It does not score it or recommend
  changes.
- People are counted per project. Someone in four projects appears in each project's table, and the
  organization total is not deduplicated.
- Groups sourced from Entra ID are expanded only as far as Azure DevOps has materialized them.
  Anything it cannot expand is listed under *Not expanded*.
- Service principals Azure DevOps cannot resolve to a display name are shown by descriptor.
- Branch counts are not available for disabled repositories.
- TFVC repositories are detected but not assessed.

## Assessment consulting

An assessment report is the starting point, not the finding. Deciding what the numbers mean for
your teams, your process, and your plans is usually the hard part. If you would like help with an
Azure DevOps assessment, migration, or Professional Scrum adoption, get in touch.

**Richard Hundhausen** · <richard@accentient.com> · [Accentient](https://accentient.com)

## Contributing

Bug reports and pull requests are welcome through
[GitHub Issues](https://github.com/accentient/ado-assessment/issues). When reporting a problem,
please include whether you are on Services or Server, the Warnings section of the report, and the
log excerpt from `logs/`. **Never send a token, and never send an unscrubbed report.**

## Related

- [digitalai-agility-to-ado](https://github.com/accentient/digitalai-agility-to-ado): migrate work
  items from Digital.ai Agility (formerly VersionOne) into Azure DevOps.

## License

[MIT](LICENSE)
