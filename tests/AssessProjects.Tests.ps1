##################################################################################################
# Unit tests for AssessProjects.ps1.
#
# The most important thing under test is that the script is read-only. That is asserted twice:
# against the source, by walking its syntax tree, and at run time, by checking the verb of every
# request the HTTP layer sends.
#
# Every test is hermetic. Nothing here resolves a credential, reaches Azure DevOps, or writes
# outside Pester's TestDrive. tests/FakeAdo.ps1 replaces the network and credential commands with
# functions that throw, so a missing mock fails the test instead of escaping it.
##################################################################################################

BeforeAll {
  $script:scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/AssessProjects.ps1'

  # Load the functions without running Main.
  $global:AssessProjectsLoadFunctionsOnly = $true
  . $script:scriptPath
  . (Join-Path $PSScriptRoot 'FakeAdo.ps1')

  $script:source = Get-Content -Path $script:scriptPath -Raw
  $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)

  function Get-EnclosingFunctionName($Node) {
    $p = $Node.Parent
    while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
    if ($p) { return $p.Name }
    return $null
  }
}

AfterAll {
  # Leave the session as we found it, or the next F5 on the script would skip Main.
  Remove-Variable -Name AssessProjectsLoadFunctionsOnly -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Read-only guarantee, in the source' {

  BeforeAll {
    $webCommands = @('Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'curl', 'wget', 'Start-BitsTransfer')
    $script:webCalls = @($script:ast.FindAll({
      param($n)
      $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $webCommands
    }.GetNewClosure(), $true))
  }

  It 'makes web requests only from Invoke-AdoGet' {
    $script:webCalls.Count | Should -BeGreaterThan 0
    foreach ($call in $script:webCalls) {
      Get-EnclosingFunctionName $call | Should -Be 'Invoke-AdoGet' -Because "line $($call.Extent.StartLineNumber) makes a web request"
    }
  }

  It 'passes -Method Get, as a literal, on every web request' {
    foreach ($call in $script:webCalls) {
      $method = $call.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Method'
      }
      $method | Should -Not -BeNullOrEmpty -Because "line $($call.Extent.StartLineNumber) must name its verb"
      $index = [array]::IndexOf($call.CommandElements, $method)
      $value = $call.CommandElements[$index + 1]
      $value | Should -BeOfType [System.Management.Automation.Language.StringConstantExpressionAst]
      $value.Value | Should -Be 'Get'
    }
  }

  It 'passes nothing to a web request that could carry a payload' {
    $allowed = @('Uri', 'Headers', 'Method', 'UseBasicParsing', 'ErrorAction')
    foreach ($call in $script:webCalls) {
      $names = @($call.CommandElements |
        Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
        ForEach-Object { $_.ParameterName })
      foreach ($n in $names) { $n | Should -BeIn $allowed -Because "line $($call.Extent.StartLineNumber) passes -$n" }
    }
  }

  It 'gives Invoke-AdoGet no parameter that could choose a verb or send a body' {
    $fn = $script:ast.Find({
      param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-AdoGet'
    }, $true)
    $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    ($params | Sort-Object) -join ',' | Should -Be 'AllPages,Raw,Uri'
  }

  It 'uses no .NET HTTP, web, or socket client, not even in the embedded C#' {
    $script:source | Should -Not -Match '\b(HttpClient|WebClient|HttpWebRequest|FtpWebRequest|TcpClient|UdpClient|Sockets?)\b'
    $script:source | Should -Not -Match '\[(System\.)?Net\.WebRequest\]'
  }

  It 'ships Main with placeholder settings, not a real organization' {
    $orgs = [regex]::Matches($script:source, 'dev\.azure\.com/([A-Za-z0-9][\w-]*)') | ForEach-Object { $_.Groups[1].Value }
    foreach ($o in $orgs) { $o | Should -Be 'YOUR-ORG' }
    $script:source | Should -Match '\$script:AdoOrgUrl = "https://dev\.azure\.com/YOUR-ORG/"'
    $script:source | Should -Match '\$script:AdoCredentialName = "YOUR-ORG-'
  }

  It 'did not run Main when the tests loaded it' {
    Get-Command AssessProjects -CommandType Function | Should -Not -BeNullOrEmpty
    $script:Assessment | Should -BeNullOrEmpty
  }
}

Describe 'Read-only guarantee, at run time' {

  BeforeEach {
    $script:Connected = $true
    $script:AdoHeaders = @{ Authorization = 'Basic fake' }
    Mock Invoke-WebRequest { New-FakeResponse @{ value = @(1) } }
  }

  It 'sends every request as a GET, with the auth header' {
    [void](Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1')
    [void](Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1' -AllPages)
    [void](Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1' -Raw)
    Should -Invoke Invoke-WebRequest -Times 3 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Headers.Authorization -eq 'Basic fake' }
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -ne 'Get' }
  }
}

Describe 'Invoke-AdoGet' {

  BeforeEach {
    $script:Connected = $true
    $script:AdoHeaders = @{ Authorization = 'Basic fake' }
  }

  It 'returns the parsed body' {
    Mock Invoke-WebRequest { New-FakeResponse @{ name = 'Portfolio'; id = 'p1' } }
    $r = Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects/p1?api-version=7.1'
    $r.name | Should -Be 'Portfolio'
  }

  It 'returns the body text with -Raw' {
    Mock Invoke-WebRequest { New-FakeResponse '42' }
    Invoke-AdoGet -Uri 'https://analytics.dev.azure.com/contoso/x/$count' -Raw | Should -Be '42'
  }

  It 'follows the x-ms-continuationtoken header and concatenates the pages' {
    Mock Invoke-WebRequest -ParameterFilter { $Uri -notlike '*continuationToken=*' } {
      New-FakeResponse @{ value = @('a', 'b') } @{ 'x-ms-continuationtoken' = 'next page' }
    }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -like '*&continuationToken=next%20page' } {
      New-FakeResponse @{ value = @('c') }
    }
    $r = Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1' -AllPages
    $r -join ',' | Should -Be 'a,b,c'
  }

  It 'follows a continuation token in the body, and reads "members" arrays' {
    Mock Invoke-WebRequest -ParameterFilter { $Uri -notlike '*continuationToken=*' } {
      New-FakeResponse @{ members = @('a'); continuationToken = 'tok' }
    }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -like '*continuationToken=tok' } {
      New-FakeResponse @{ members = @('b'); continuationToken = $null }
    }
    $r = Invoke-AdoGet -Uri 'https://vsaex.dev.azure.com/contoso/_apis/userentitlements?api-version=7.1' -AllPages
    $r -join ',' | Should -Be 'a,b'
  }

  It 'follows an OData nextLink' {
    Mock Invoke-WebRequest -ParameterFilter { $Uri -notlike '*skiptoken*' } {
      New-FakeResponse @{ value = @('a'); '@odata.nextLink' = 'https://analytics.dev.azure.com/contoso/p/_odata/WorkItems?$skiptoken=2' }
    }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -like '*skiptoken=2' } { New-FakeResponse @{ value = @('b') } }
    $r = Invoke-AdoGet -Uri 'https://analytics.dev.azure.com/contoso/p/_odata/WorkItems' -AllPages
    $r -join ',' | Should -Be 'a,b'
  }

  It 'stops a server that never stops paging' {
    Mock Invoke-WebRequest { New-FakeResponse @{ value = @(1) } @{ 'x-ms-continuationtoken' = 'again' } }
    { Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/x?api-version=7.1' -AllPages } | Should -Throw '*Paging guard*'
  }

  It 'refuses an HTML sign-in page instead of parsing it' {
    Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<html>Sign in</html>'; Headers = @{ 'Content-Type' = 'text/html; charset=utf-8' } } }
    { Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1' } | Should -Throw '*HTML sign-in page*'
  }

  It 'retries once with a -preview api-version when the server asks for one' {
    Mock Invoke-WebRequest -ParameterFilter { $Uri -like '*api-version=7.1' } {
      throw (New-FakeHttpError 400 'VssInvalidPreviewVersionException: The requested version 7.1 requires -preview.')
    }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -like '*api-version=7.1-preview' } { New-FakeResponse @{ ok = $true } }
    (Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/distributedtask/queues?api-version=7.1').ok | Should -BeTrue
    Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' }
  }

  It 'rethrows any other failure' {
    Mock Invoke-WebRequest { throw (New-FakeHttpError 403 'Forbidden.') }
    { Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1' } | Should -Throw
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly
  }

  It 'connects first when it has not yet, and never reads a real credential' {
    $script:Connected = $false
    $script:AdoOrgUrl = 'https://dev.azure.com/contoso/'
    Mock Get-AdoPat { 'fake-pat' }
    Mock Invoke-WebRequest { New-FakeResponse @{ ok = $true } }
    [void](Invoke-AdoGet -Uri 'https://dev.azure.com/contoso/_apis/projects?api-version=7.1')
    $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':fake-pat'))
    Should -Invoke Get-AdoPat -Times 1 -Exactly
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq $expected }
  }
}

Describe 'Get-AdoSkipPaged' {

  It 'pages with $top and $skip until a short page' {
    Mock Invoke-AdoGet -ParameterFilter { $Uri -like '*$skip=0' } { [pscustomobject]@{ value = @('a', 'b') } }
    Mock Invoke-AdoGet -ParameterFilter { $Uri -like '*$skip=2' } { [pscustomobject]@{ value = @('c') } }
    $r = Get-AdoSkipPaged -Uri 'https://dev.azure.com/contoso/_apis/projects/p1/teams?api-version=7.1' -PageSize 2
    $r -join ',' | Should -Be 'a,b,c'
    Should -Invoke Invoke-AdoGet -Times 1 -Exactly -ParameterFilter { $Uri -like '*?api-version=7.1&$top=2&$skip=0' }
  }
}

Describe 'ConvertFrom-AdoJson' {

  It 'survives a property whose name is an empty string' {
    (ConvertFrom-AdoJson '{"":1,"name":"Bug"}').name | Should -Be 'Bug'
  }
}

Describe 'Organization settings' {

  It 'reads the organization from <Url>' -ForEach @(
    @{ Url = 'https://dev.azure.com/contoso/';        Org = 'contoso' }
    @{ Url = 'https://dev.azure.com/contoso';         Org = 'contoso' }
    @{ Url = ' https://contoso.visualstudio.com/ ';   Org = 'contoso' }
  ) {
    $script:AdoOrgUrl = $Url
    Get-AdoOrgName | Should -Be $Org
  }

  It 'tells you to set the URL when it is <Case>' -ForEach @(
    @{ Case = 'the placeholder'; Url = 'https://dev.azure.com/YOUR-ORG/' }
    @{ Case = 'empty';           Url = '' }
  ) {
    $script:AdoOrgUrl = $Url
    { Get-AdoOrgName } | Should -Throw '*Set $script:AdoOrgUrl*'
  }

  It 'rejects a URL that is not Azure DevOps Services' {
    $script:AdoOrgUrl = 'https://tfs.contoso.example/tfs/DefaultCollection/'
    { Get-AdoOrgName } | Should -Throw '*Unrecognized organization URL*'
  }

  It 'tells you to set the credential name when it is empty' {
    $script:AdoCredentialName = ''
    { Get-AdoCredentialName } | Should -Throw '*Set $script:AdoCredentialName*'
  }
}

Describe 'Identity helpers' {

  It 'classifies <Descriptor> as <Kind>' -ForEach @(
    @{ Descriptor = 'vssgp.x'; Kind = 'ADO group';             IsGroup = $true }
    @{ Descriptor = 'aadgp.x'; Kind = 'Entra group';           IsGroup = $true }
    @{ Descriptor = 'aad.x';   Kind = 'User';                  IsGroup = $false }
    @{ Descriptor = 'msa.x';   Kind = 'User (MSA)';            IsGroup = $false }
    @{ Descriptor = 'aadsp.x'; Kind = 'Service principal';     IsGroup = $false }
    @{ Descriptor = 'svc.x';   Kind = 'Service account';       IsGroup = $false }
    @{ Descriptor = 'bnd.x';   Kind = 'User (invite pending)'; IsGroup = $false }
    @{ Descriptor = 'xyz.x';   Kind = 'Other';                 IsGroup = $false }
  ) {
    Get-SubjectKind $Descriptor | Should -Be $Kind
    Test-IsGroupDescriptor $Descriptor | Should -Be $IsGroup
  }

  It 'shows a subject Graph cannot resolve by its descriptor' {
    $script:SubjectCache = @{}
    Mock Invoke-AdoGet { throw (New-FakeHttpError 404 'Not found.') }
    (Get-AdoSubject 'aad.ghost').displayName | Should -Be '(unresolved aad.ghost)'
  }
}

Describe 'Expand-AdoGroup' {

  BeforeEach {
    $script:ExpandCache = @{}
    Mock Invoke-AdoGet -ParameterFilter { $Uri -like '*memberships/vssgp.root?*' } {
      @(@{ memberDescriptor = 'aad.a' }, @{ memberDescriptor = 'aadgp.child' }, @{ memberDescriptor = 'vssgp.locked' })
    }
    # The child group contains the root again: a cycle must not loop.
    Mock Invoke-AdoGet -ParameterFilter { $Uri -like '*memberships/aadgp.child?*' } {
      @(@{ memberDescriptor = 'aad.b' }, @{ memberDescriptor = 'AAD.A' }, @{ memberDescriptor = 'vssgp.root' })
    }
    Mock Invoke-AdoGet -ParameterFilter { $Uri -like '*memberships/vssgp.locked?*' } { throw (New-FakeHttpError 403 'Denied.') }
  }

  It 'counts distinct people through nested groups, ignoring case and cycles' {
    $r = Expand-AdoGroup -Descriptor 'vssgp.root'
    @($r.Users | Sort-Object) -join ',' | Should -Be 'aad.a,aad.b'
    @($r.Groups) -join ',' | Should -Be 'aadgp.child,vssgp.locked'
  }

  It 'lists a nested group it could not expand, so the count reads as a floor' {
    @((Expand-AdoGroup -Descriptor 'vssgp.root').Unexpanded) | Should -Be @('vssgp.locked')
  }

  It 'expands each group once per run' {
    [void](Expand-AdoGroup -Descriptor 'vssgp.root')
    [void](Expand-AdoGroup -Descriptor 'vssgp.root')
    Should -Invoke Invoke-AdoGet -Times 1 -Exactly -ParameterFilter { $Uri -like '*memberships/vssgp.root?*' }
  }
}

Describe 'Invoke-Collector' {

  BeforeEach {
    Mock Write-Host { }
    $script:project = [pscustomobject]@{ Errors = New-Object System.Collections.Generic.List[string] }
  }

  It 'returns what the collector returns' {
    Invoke-Collector -Name 'Repos' -Scope 'Code (Read)' -Project $script:project -Script { 'ok' } | Should -Be 'ok'
    $script:project.Errors.Count | Should -Be 0
  }

  It 'turns a 403 into a warning naming the scope and quoting the server, and carries on' {
    $r = Invoke-Collector -Name 'Test plans' -Scope 'Test Management (Read)' -Project $script:project -Script {
      throw (New-FakeHttpError 403 'TF400409: You do not have licensing rights.')
    }
    $r | Should -BeNullOrEmpty
    $script:project.Errors[0] | Should -BeLike "Test plans: HTTP 403 (forbidden). Either the PAT lacks the 'Test Management (Read)' scope*Server said: TF400409: You do not have licensing rights."
  }

  It 'explains a 401 as a missing, expired, or under-scoped PAT' {
    [void](Invoke-Collector -Name 'Repos' -Scope 'Code (Read)' -Project $script:project -Script { throw (New-FakeHttpError 401 $null) })
    $script:project.Errors[0] | Should -Be "Repos: HTTP 401 (unauthorized). The PAT is missing, expired, or lacks the 'Code (Read)' scope."
  }

  It 'records a failure that is not HTTP as it is' {
    [void](Invoke-Collector -Name 'Repos' -Scope 'Code (Read)' -Project $script:project -Script { throw 'boom' })
    $script:project.Errors[0] | Should -Be 'Repos: boom'
  }
}

Describe 'Report formatting helpers' {

  It 'escapes pipes and flattens line breaks in table cells' {
    MdCell "a|b`r`nc " | Should -Be 'a\|b c'
    MdCell $null | Should -Be ''
  }

  It 'formats dates, and passes through what is not a date' {
    Fmt-Date '2026-03-04T12:00:00Z' | Should -Be '2026-03-04'
    Fmt-Date $null | Should -Be ''
    Fmt-Date 'not a date' | Should -Be 'not a date'
  }

  It 'shows a missing number as n/a, and zero as 0' {
    Fmt-Num $null | Should -Be 'n/a'
    Fmt-Num 0 | Should -Be '0'
  }

  It 'describes <Days> days ago as "<Text>"' -ForEach @(
    @{ Days = 0.1; Text = 'today' }
    @{ Days = 10;  Text = '10 d ago' }
    @{ Days = 90;  Text = '3 mo ago' }
    @{ Days = 730; Text = '2 yr ago' }
  ) {
    Fmt-Age ((Get-Date).AddDays(-$Days)) | Should -Be $Text
  }

  It 'truncates long name lists with a count of the rest' {
    Join-Names @('a', 'b', 'c') 2 | Should -Be 'a, b (+1 more)'
    Join-Names @('a|b', $null, '') | Should -Be 'a\|b'
    Join-Names @() | Should -Be ''
  }

  It 'coalesces to the first value that is neither null nor empty, keeping zero' {
    Coalesce $null '' 'x' | Should -Be 'x'
    Coalesce 0 'x' | Should -Be 0
    Coalesce $null '' | Should -BeNullOrEmpty
  }

  It 'translates project states' {
    ConvertTo-ProjectStateText 'wellFormed' | Should -Be 'Active'
    ConvertTo-ProjectStateText 'somethingNew' | Should -Be 'somethingNew'
  }

  It 'counts classification nodes, root included' {
    $tree = [pscustomobject]@{ children = @([pscustomobject]@{ children = @([pscustomobject]@{}, [pscustomobject]@{}) }, [pscustomobject]@{}) }
    Measure-ClassificationNodes $tree | Should -Be 5
  }
}
