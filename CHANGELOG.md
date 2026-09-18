# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Read-only assessment of an Azure DevOps Services organization: projects, teams, security groups,
  people, work items, repositories, pipelines, feeds, wikis, test plans, service connections, and
  agent pools.
- Assess every project, named projects, or the projects listed in a CSV file.
- Markdown report and JSON output written to `reports/`.
- PAT stored in Windows Credential Manager, with `Save-AdoPat`, `Remove-AdoPat`, and
  `Test-AdoConnection` helpers.
- Hermetic Pester test suite, including an end-to-end run against a fake organization. It runs in
  GitHub Actions on PowerShell 7 and Windows PowerShell 5.1.

[Unreleased]: https://github.com/accentient/ado-assessment/commits/main
