##################################################################################################
# End-to-end tests for AssessProjects.ps1.
#
# A full assessment runs against "contoso", the fake organization in tests/FakeAdo.ps1, with only
# Invoke-WebRequest and Get-AdoPat mocked. Everything between them is the real script: paging,
# group expansion, every collector, error handling, and both report writers. The fake has one
# healthy project and one the token can only partly read, so the report's n/a and Warnings paths
# are covered as well as the happy one.
#
# Every test is hermetic. Nothing here resolves a credential or reaches Azure DevOps, and reports
# are written to Pester's TestDrive.
##################################################################################################

BeforeAll {
  $script:scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/AssessProjects.ps1'

  # Load the functions without running Main.
  $global:AssessProjectsLoadFunctionsOnly = $true
  . $script:scriptPath
  . (Join-Path $PSScriptRoot 'FakeAdo.ps1')

  function Use-FakeOrganization {
    # Call from a BeforeAll: mocks live in the block that defines them.
    $script:AdoOrgUrl = 'https://dev.azure.com/contoso/'
    $script:AdoCredentialName = 'contoso-assessment-PAT'
    Reset-FakeAdo
    Mock Get-AdoPat { 'fake-pat' }
    Mock Invoke-WebRequest { Invoke-FakeAdo -Uri $Uri -Headers $Headers -Method $Method }
    Mock Write-Host { }
  }
}

AfterAll {
  # Leave the session as we found it, or the next F5 on the script would skip Main.
  Remove-Variable -Name AssessProjectsLoadFunctionsOnly -Scope Global -ErrorAction SilentlyContinue
}

Describe 'A full assessment of a fake organization' {

  BeforeAll {
    Use-FakeOrganization
    $script:reportPath = Join-Path $TestDrive 'ADO-Assessment-test.md'
    $script:results = AssessProjects -All -OutputPath $script:reportPath
    $script:report = Get-Content -Path $script:reportPath -Raw
    $script:lines = @(Get-Content -Path $script:reportPath)
    $script:portfolio = $script:results | Where-Object Name -eq 'Portfolio'
    $script:legacy = $script:results | Where-Object Name -eq 'Legacy'

    function Get-Section([string]$Heading) {
      # The report lines from a project's "## Heading" up to the next "## ".
      $start = [array]::IndexOf($script:lines, "## $Heading")
      $end = $start + 1
      while ($end -lt $script:lines.Count -and $script:lines[$end] -notlike '## *') { $end++ }
      return $script:lines[$start..($end - 1)]
    }
  }

  Context 'staying read-only and hermetic' {

    It 'sent every request as a GET' {
      $script:FakeRequests.Count | Should -BeGreaterThan 50
      @($script:FakeRequests | Where-Object Method -ne 'Get') | Should -BeNullOrEmpty
    }

    It 'authenticated every request with the fake token, never a stored one' {
      # The real Get-AdoPat is replaced by a guard that throws, so this header can only come from
      # the mock.
      $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':fake-pat'))
      @($script:FakeRequests | Where-Object Authorization -ne $expected) | Should -BeNullOrEmpty
    }

    It 'only called endpoints the fake organization knows' {
      @($script:FakeUnrouted) | Should -BeNullOrEmpty
    }
  }

  Context 'output files' {

    It 'writes the Markdown report and the JSON next to it' {
      $script:reportPath | Should -Exist
      [IO.Path]::ChangeExtension($script:reportPath, '.json') | Should -Exist
    }

    It 'returns one result per project, sorted by name' {
      @($script:results.Name) -join ',' | Should -Be 'Legacy,Portfolio'
    }

    It 'puts everything behind the report in the JSON' {
      $json = Get-Content -Path ([IO.Path]::ChangeExtension($script:reportPath, '.json')) -Raw | ConvertFrom-Json
      @($json).Count | Should -Be 2
      $p = @($json) | Where-Object Name -eq 'Portfolio'
      @($p.Security.People).Count | Should -Be 6
      ($p.Security.People | Where-Object DisplayName -eq 'Avery Park').Descriptor | Should -Be 'aad.avery'
      @(($json | Where-Object Name -eq 'Legacy').Errors).Count | Should -Be 2
    }
  }

  Context 'the organization summary' {

    It 'summarizes the healthy project' {
      $script:report | Should -Match '(?m)^\| Portfolio \| Contoso Scrum \(Scrum\) \| 1 \| 6 \| 1 \| 4 \| 2 \| 5 \| 552 \| 3 \| 2 \| 1 \| 1 \| 2026-09-14 \('
    }

    It 'shows n/a where the token could not read' {
      $script:report | Should -Match '(?m)^\| Legacy \| Agile \| 0 \| 0 \| 0 \| 0 \| 0 \| 2 \| n/a \| 0 \| 0 \| 0 \| 0 \|'
    }
  }

  Context 'teams, groups, and people' {

    It 'shows the inherited process with its parent' {
      $script:portfolio.Core.Process | Should -Be 'Contoso Scrum'
      $script:portfolio.Core.ProcessParent | Should -Be 'Scrum'
      $script:lines | Should -Contain '| Process | Contoso Scrum (inherited from Scrum) |'
    }

    It 'counts a team by its people, expanding the Entra group inside it' {
      $team = $script:portfolio.Security.Teams[0]
      $team.People | Should -Be 3
      $team.Contributors | Should -Be 3
      $team.ProjectAdmins | Should -Be 1
      $team.IsDefault | Should -BeTrue
      $script:lines | Should -Contain '| Portfolio Team (default) | 3 | 3 | 0 | 1 | Avery Park | Avery Park, Blake Chen, Casey Diaz [via groups: Developers] |'
    }

    It 'lists a group it could not expand' {
      $script:lines | Should -Contain '| Release Approvers | 1 | 1 | Offshore Contractors |'
    }

    It 'resolves roles, teams, other groups, and access level for each person' {
      $script:lines | Should -Contain '| Avery Park | avery@contoso.example | User | Project Admin, Contributor | Portfolio Team |  | Basic | 2026-09-01 |'
      $script:lines | Should -Contain '| Blake Chen | blake@contoso.example | User | Contributor | Portfolio Team | Release Approvers | Stakeholder | 2026-08-15 |'
      $script:lines | Should -Contain '| Dana Evans | dana@contoso.example | User | Reader |  |  |  |  |'
    }

    It 'tells service principals from users' {
      ($script:portfolio.Security.People | Where-Object DisplayName -eq 'Contoso Build').Kind | Should -Be 'Service principal'
    }

    It 'shows an identity Graph cannot resolve by its descriptor' {
      $script:portfolio.Security.People.DisplayName | Should -Contain '(unresolved aad.ghost)'
    }
  }

  Context 'work items' {

    It 'counts work items per type, including custom and empty types' {
      $script:portfolio.WorkItems.Total | Should -Be 552
      $script:lines | Should -Contain '| Risk | 2 | Contoso.Risk |'
      $script:lines | Should -Contain '| Epic | 0 | Microsoft.VSTS.WorkItemTypes.Epic |'
      $script:lines | Should -Contain '| Impediment (disabled) | 0 | Microsoft.VSTS.WorkItemTypes.Impediment |'
    }

    It 'counts area and iteration paths' {
      $script:lines | Should -Contain '| Work item types | 5 | 552 work items, last change 2026-09-10; 3 area paths, 4 iteration paths |'
    }

    It 'builds the cross-project matrix, with - for a missing type and n/a for an unreadable count' {
      $script:lines | Should -Contain '| Work item type | Legacy | Portfolio | Total |'
      $script:lines | Should -Contain '| Bug | n/a | 30 | 30 |'
      $script:lines | Should -Contain '| User Story | n/a | - | 0 |'
      $script:lines | Should -Contain '| **Total** | n/a | **552** | **552** |'
    }
  }

  Context 'code, pipelines, and packages' {

    It 'flags empty and disabled repositories and sums their size' {
      $r = $script:portfolio.Repos
      $r.Count | Should -Be 3
      $r.Empty | Should -Be 1
      $r.Disabled | Should -Be 1
      $r.TotalSizeMB | Should -Be 6
      ($r.Repos | Where-Object Name -eq 'web').Branches | Should -Be 2
      ($r.Repos | Where-Object Name -eq 'web').LastAuthor | Should -Be 'Blake Chen'
    }

    It 'separates YAML from classic pipelines and counts the disabled ones' {
      # Per pipeline, not just the totals: swapping the two kinds would leave the totals unchanged.
      ($script:portfolio.Pipelines.Pipelines | Where-Object Name -eq 'web-ci').Kind | Should -Be 'YAML'
      ($script:portfolio.Pipelines.Pipelines | Where-Object Name -eq 'old-build').Kind | Should -Be 'Classic'
      ($script:portfolio.Pipelines.Pipelines | Where-Object Name -eq 'web-ci').LastResult | Should -Be 'succeeded'
      $script:lines | Should -Contain '| Build pipelines | 2 | 1 YAML, 1 classic, 1 paused/disabled, last run 2026-09-14 |'
    }

    It 'reports only the feeds that belong to the project' {
      $script:portfolio.Feeds.Count | Should -Be 1
      $script:portfolio.Feeds.Packages | Should -Be 3
      $script:legacy.Feeds.Count | Should -Be 0
      $script:lines | Should -Contain '| contoso-packages | 3 | npm, NuGet | enabled |'
    }

    It 'notices TFVC content in a Git project' {
      $script:lines | Should -Contain '| Source control | Git (TFVC content also present) |'
    }

    It 'lists wikis, test plans, service connections, and agent pools' {
      $section = Get-Section 'Portfolio'
      $section | Should -Contain '| Wikis | 1 | Portfolio.wiki (projectWiki) |'
      $section | Should -Contain '| Test plans | 1 | Release 1 |'
      $section | Should -Contain '| Service connections | 1 | azurerm |'
      $section | Should -Contain '| Agent pools available | 1 | Azure Pipelines |'
    }
  }

  Context 'degrading gracefully' {

    It 'records no warnings for the healthy project' {
      $script:portfolio.Errors.Count | Should -Be 0
      Get-Section 'Portfolio' | Should -Not -Contain '### Warnings'
    }

    It 'names the scope and quotes the server for each area it could not read' {
      $warnings = @(Get-Section 'Legacy' | Where-Object { $_ -like '- *' })
      $warnings.Count | Should -Be 2
      $warnings[0] | Should -Match "^- Work item counts \(Analytics\): HTTP 403 .*'Analytics \(Read\)'.*Server said: VS403527"
      $warnings[1] | Should -Match "^- Test plans: HTTP 403 .*'Test Management \(Read\)'.*Server said: TF400409"
    }

    It 'still reports what it could read in that project' {
      $script:legacy.WorkItems.TypeCount | Should -Be 2
      $script:lines | Should -Contain '| Work item types | 2 | n/a work items |'
    }

    It 'tells an empty area (0) from one it could not read (left out)' {
      $section = Get-Section 'Legacy'
      $section | Should -Contain '| Wikis | 0 |  |'
      @($section | Where-Object { $_ -like '| Test plans |*' }) | Should -BeNullOrEmpty
    }
  }
}

Describe 'Choosing which projects to assess' {

  BeforeAll { Use-FakeOrganization }

  It 'matches names without regard to case, and reports the ones it cannot find' {
    $path = Join-Path $TestDrive 'named.md'
    $r = AssessProjects -Projects ' portfolio ', 'Nope' -OutputPath $path
    @($r.Name) | Should -Be @('Portfolio')
    Get-Content $path | Should -Contain '> Not found or not visible to this PAT: Nope'
  }

  It 'reads a CSV, skipping the header, comments, and blank lines, and splitting on commas' {
    $csv = Join-Path $TestDrive 'projects.csv'
    Set-Content -Path $csv -Value @('Project', '# the ones in scope', 'Portfolio', '', '"Legacy", Portfolio')
    $r = AssessProjects -CsvPath $csv -OutputPath (Join-Path $TestDrive 'csv.md')
    @($r.Name) -join ',' | Should -Be 'Legacy,Portfolio'
  }

  It 'stops when nothing matches' {
    { AssessProjects -Projects 'Nope' -OutputPath (Join-Path $TestDrive 'none.md') } | Should -Throw 'No matching projects to assess.'
  }

  It 'stops when the CSV is missing' {
    { AssessProjects -CsvPath (Join-Path $TestDrive 'missing.csv') } | Should -Throw 'CSV file not found*'
  }
}

Describe 'Test-AdoConnection' {

  BeforeAll { Use-FakeOrganization }

  It 'shows who the token belongs to and which projects it can see' {
    Test-AdoConnection
    Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Connected to contoso as Avery Park (avery@contoso.example)' }
    Should -Invoke Write-Host -ParameterFilter { $Object -eq '2 project(s) visible: Legacy, Portfolio' }
  }
}
