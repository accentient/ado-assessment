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
| ------------------------- | --------- | --------------------------------------------
