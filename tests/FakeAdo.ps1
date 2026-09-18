##################################################################################################
# Shared test fixture. Dot-source it AFTER AssessProjects.ps1, so its guards replace the real
# commands.
#
# 1. A hermetic guard: Invoke-WebRequest, Invoke-RestMethod, and every credential function are
#    replaced by functions that throw. A code path no test has mocked fails loudly instead of
#    reaching the network or Windows Credential Manager.
# 2. FakeHttpException: an error shaped like a real HTTP failure (status code plus the server's
#    JSON message), so the script's error handling sees what it would see in production.
# 3. A fake organization, "contoso", served by URL. Mock Invoke-WebRequest with Invoke-FakeAdo and
#    the whole assessment runs end to end with no network. Every name in it is synthetic.
##################################################################################################

# -------------------------------------------------------------------------------- hermetic guard

function Invoke-WebRequest {
  [CmdletBinding()]
  param([string]$Uri, [hashtable]$Headers, [string]$Method, [switch]$UseBasicParsing)
  throw "Hermetic test: unmocked Invoke-WebRequest $Method $Uri"
}

function Invoke-RestMethod {
  [CmdletBinding()]
  param([string]$Uri, [hashtable]$Headers, [string]$Method, [switch]$UseBasicParsing)
  throw "Hermetic test: unmocked Invoke-RestMethod $Method $Uri"
}

function Get-AdoPat    { throw "Hermetic test: tried to read a PAT from Windows Credential Manager." }
function Save-AdoPat   { throw "Hermetic test: tried to write to Windows Credential Manager." }
function Remove-AdoPat { throw "Hermetic test: tried to delete from Windows Credential Manager." }

# -------------------------------------------------------------------------------- fake HTTP

class FakeHttpException : System.Exception {
  [object]$Response
  FakeHttpException([string]$Message, [int]$Status) : base($Message) {
    $this.Response = [pscustomobject]@{ StatusCode = $Status }
  }
}

function New-FakeHttpError([int]$Status, [string]$ServerMessage) {
  # Throw the result. Invoke-Collector reads the status from Exception.Response and the server's
  # message from ErrorDetails, as it does for a real Invoke-WebRequest failure.
  $ex = [FakeHttpException]::new("Response status code does not indicate success: $Status.", $Status)
  $er = [System.Management.Automation.ErrorRecord]::new($ex, 'FakeHttp', 'InvalidOperation', $null)
  if ($ServerMessage) {
    $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((ConvertTo-Json -InputObject @{ message = $ServerMessage } -Compress))
  }
  return $er
}

function New-FakeResponse($Body, [hashtable]$Headers = @{}) {
  # The parts of an Invoke-WebRequest response that Invoke-AdoGet reads.
  $h = @{ 'Content-Type' = 'application/json; charset=utf-8' }
  foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  $content = $Body
  if ($Body -isnot [string]) { $content = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
  return [pscustomobject]@{ Content = $content; Headers = $h }
}

# -------------------------------------------------------------------------------- fake organization
#
# Two projects:
#   Portfolio  healthy: nested and Entra groups, a team, custom process, repos, pipelines, feeds.
#   Legacy     restricted: Analytics and Test Plans refuse the token, and TFVC content is present.

$script:FakeUsers = @{
  'aad.avery'   = @{ descriptor = 'aad.avery';   displayName = 'Avery Park';    mailAddress = 'avery@contoso.example'; principalName = 'avery@contoso.example' }
  'aad.blake'   = @{ descriptor = 'aad.blake';   displayName = 'Blake Chen';    mailAddress = 'blake@contoso.example'; principalName = 'blake@contoso.example' }
  'aad.casey'   = @{ descriptor = 'aad.casey';   displayName = 'Casey Diaz';    mailAddress = 'casey@contoso.example'; principalName = 'casey@contoso.example' }
  'aad.dana'    = @{ descriptor = 'aad.dana';    displayName = 'Dana Evans';    mailAddress = 'dana@contoso.example';  principalName = 'dana@contoso.example' }
  'aadsp.build' = @{ descriptor = 'aadsp.build'; displayName = 'Contoso Build'; mailAddress = '';                      principalName = '' }
  # aad.ghost is deliberately missing: Graph cannot resolve it.
}

# Members = $null means Graph refuses to expand the group.
$script:FakeGroups = @{
  'vssgp.admins'    = @{ displayName = 'Project Administrators'; Members = @('aad.avery') }
  'vssgp.contrib'   = @{ displayName = 'Contributors';           Members = @('vssgp.team', 'aadgp.devs', 'aadsp.build') }
  'vssgp.readers'   = @{ displayName = 'Readers';                Members = @('aad.dana', 'aad.ghost') }
  'vssgp.valid'     = @{ displayName = 'Project Valid Users';    Members = @('vssgp.admins', 'vssgp.contrib', 'vssgp.readers') }
  'vssgp.team'      = @{ displayName = 'Portfolio Team';         Members = @('aad.avery', 'aadgp.devs') }
  'vssgp.approvers' = @{ displayName = 'Release Approvers';      Members = @('aad.blake', 'vssgp.offshore') }
  'aadgp.devs'      = @{ displayName = 'Developers';             Members = @('aad.blake', 'aad.casey') }
  'vssgp.offshore'  = @{ displayName = 'Offshore Contractors';   Members = $null }
}

$script:FakeDescriptors = @{ p1 = 'scp.p1'; p2 = 'scp.p2'; t1 = 'vssgp.team' }

$script:FakeProjects = @{
  p1 = @{
    Detail = @{
      id = 'p1'; name = 'Portfolio'; description = 'Portfolio planning.'; state = 'wellFormed'; visibility = 'private'
      defaultTeam = @{ id = 't1' }
      capabilities = @{ processTemplate = @{ templateName = 'Contoso Scrum'; templateTypeId = 'proc-custom' }; versioncontrol = @{ sourceControlType = 'Git' } }
    }
    ScopedUsers  = @('aad.avery', 'aad.blake', 'aad.dana')
    ScopedGroups = @('vssgp.admins', 'vssgp.contrib', 'vssgp.readers', 'vssgp.valid', 'vssgp.team', 'vssgp.approvers')
    Teams        = @(@{ id = 't1'; name = 'Portfolio Team' })
    TeamMembers  = @{
      t1 = @(
        @{ identity = @{ displayName = 'Avery Park'; descriptor = 'aad.avery' }; isTeamAdmin = $true },
        @{ identity = @{ displayName = 'Developers'; descriptor = 'aadgp.devs'; isContainer = $true }; isTeamAdmin = $false }
      )
    }
    WorkItemTypes = @(
      @{ name = 'Epic';                 referenceName = 'Microsoft.VSTS.WorkItemTypes.Epic' },
      @{ name = 'Product Backlog Item'; referenceName = 'Microsoft.VSTS.WorkItemTypes.ProductBacklogItem' },
      @{ name = 'Bug';                  referenceName = 'Microsoft.VSTS.WorkItemTypes.Bug' },
      @{ name = 'Task';                 referenceName = 'Microsoft.VSTS.WorkItemTypes.Task' },
      @{ name = 'Risk';                 referenceName = 'Contoso.Risk' },
      @{ name = 'Impediment';           referenceName = 'Microsoft.VSTS.WorkItemTypes.Impediment'; isDisabled = $true }
    )
    # Epic and Impediment have no work items, so Analytics returns no row for them.
    WorkItemCounts = @(
      @{ WorkItemType = 'Product Backlog Item'; Count = 120 },
      @{ WorkItemType = 'Bug';                  Count = 30 },
      @{ WorkItemType = 'Task';                 Count = 400 },
      @{ WorkItemType = 'Risk';                 Count = 2 }
    )
    LastChanged = '2026-09-10T12:00:00Z'
    # 3 area paths (root + 2), 4 iteration paths (root + 1 + 2)
    Nodes = @(
      @{ structureType = 'area';      children = @(@{ name = 'A' }, @{ name = 'B' }) },
      @{ structureType = 'iteration'; children = @(@{ name = 'R1'; children = @(@{ name = 'S1' }, @{ name = 'S2' }) }) }
    )
    Repos = @(
      @{ id = 'r1'; name = 'web';        defaultBranch = 'refs/heads/main'; size = 5242880 },
      @{ id = 'r2'; name = 'empty-repo'; size = 0 },
      @{ id = 'r3'; name = 'archive';    defaultBranch = 'refs/heads/main'; size = 1048576; isDisabled = $true }
    )
    Tfvc = $null
    Builds = @(
      @{ name = 'web-ci';    path = '\'; process = @{ type = 2 }; queueStatus = 'enabled'; repository = @{ name = 'web' }
         latestCompletedBuild = @{ finishTime = '2026-09-14T12:00:00Z'; result = 'succeeded' } },
      @{ name = 'old-build'; path = '\legacy'; process = @{ type = 1 }; queueStatus = 'disabled'; repository = @{ name = 'web' } }
    )
    Releases  = @(@{ name = 'Deploy web'; path = '\'; modifiedOn = '2025-01-01T12:00:00Z' })
    Wikis     = @(@{ name = 'Portfolio.wiki'; type = 'projectWiki' })
    TestPlans = @(@{ id = 1; name = 'Release 1' })
    Endpoints = @(@{ name = 'azure-prod'; type = 'azurerm'; isShared = $false })
    Queues    = @(@{ name = 'Azure Pipelines'; pool = @{ isHosted = $true } })
  }
  p2 = @{
    Detail = @{
      id = 'p2'; name = 'Legacy'; description = ''; state = 'wellFormed'; visibility = 'private'
      capabilities = @{ processTemplate = @{ templateName = 'Agile'; templateTypeId = 'proc-agile' }; versioncontrol = @{ sourceControlType = 'Git' } }
    }
    ScopedUsers   = @()
    ScopedGroups  = @()
    Teams         = @()
    TeamMembers   = @{}
    WorkItemTypes = @(
      @{ name = 'Bug';        referenceName = 'Microsoft.VSTS.WorkItemTypes.Bug' },
      @{ name = 'User Story'; referenceName = 'Microsoft.VSTS.WorkItemTypes.UserStory' }
    )
    WorkItemCounts = 'VS403527: Access to data from the Analytics OData endpoint is not available for all users.'
    Nodes     = @()
    Repos     = @()
    Tfvc      = @(@{ path = '$/Legacy'; isFolder = $true })
    Builds    = @()
    Releases  = @()
    Wikis     = @()
    TestPlans = 'TF400409: You do not have licensing rights to access this feature: Test Plans.'
    Endpoints = @()
    Queues    = @()
  }
}

$script:FakeCommits = @{
  r1 = @(@{ committer = @{ date = '2026-09-12T12:00:00Z' }; author = @{ name = 'Blake Chen' } })
  r2 = @()
}
$script:FakeRefs = @{
  r1 = @(@{ name = 'refs/heads/main' }, @{ name = 'refs/heads/dev' })
  r2 = @()
}

function Get-FakeValue($Data) {
  # A string in the fixture stands for "the server refused this with that message".
  if ($Data -is [string]) { throw (New-FakeHttpError 403 $Data) }
  return @{ value = @($Data | Where-Object { $null -ne $_ }) }
}

function Get-FakeGroupSubject([string]$Descriptor) {
  return @{ descriptor = $Descriptor; displayName = $script:FakeGroups[$Descriptor].displayName }
}

$core  = '^https://dev\.azure\.com/contoso/'
$graph = '^https://vssps\.dev\.azure\.com/contoso/_apis/graph/'

# First match wins. Each body runs with $Matches from its pattern.
$script:FakeRoutes = @(
  @{ P = "$($core)_apis/connectionData\?"; B = {
      @{ authenticatedUser = @{ id = 'u1'; providerDisplayName = 'Avery Park'; properties = @{ Account = @{ '$value' = 'avery@contoso.example' } } } } } }
  @{ P = "$($core)_apis/projects\?"; B = {
      @{ value = @(@{ id = 'p1'; name = 'Portfolio' }, @{ id = 'p2'; name = 'Legacy' }) } } }
  @{ P = "$($core)_apis/projects/(p\d)\?"; B = { $script:FakeProjects[$Matches[1]].Detail } }
  @{ P = "$($core)_apis/projects/(p\d)/teams\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Teams } }
  @{ P = "$($core)_apis/projects/(p\d)/teams/(t\d)/members\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].TeamMembers[$Matches[2]] } }
  @{ P = "$($core)_apis/work/processes\?"; B = {
      Get-FakeValue @(
        @{ typeId = 'proc-scrum';  name = 'Scrum' },
        @{ typeId = 'proc-agile';  name = 'Agile' },
        @{ typeId = 'proc-custom'; name = 'Contoso Scrum'; parentProcessTypeId = 'proc-scrum' }) } }

  # Member Entitlement Management pages with a continuation token in the body.
  @{ P = '^https://vsaex\.dev\.azure\.com/contoso/_apis/userentitlements\?.*continuationToken=page2'; B = {
      @{ members = @(@{ user = @{ descriptor = 'aad.blake' }; accessLevel = @{ licenseDisplayName = 'Stakeholder' }; lastAccessedDate = '2026-08-15T12:00:00Z' }); continuationToken = $null } } }
  @{ P = '^https://vsaex\.dev\.azure\.com/contoso/_apis/userentitlements\?'; B = {
      @{ members = @(@{ user = @{ descriptor = 'aad.avery' }; accessLevel = @{ licenseDisplayName = 'Basic' }; lastAccessedDate = '2026-09-01T12:00:00Z' }); continuationToken = 'page2' } } }

  @{ P = "$($graph)descriptors/(\w+)\?"; B = { @{ value = $script:FakeDescriptors[$Matches[1]] } } }
  @{ P = "$($graph)users\?scopeDescriptor=scp\.(p\d)"; B = {
      Get-FakeValue @($script:FakeProjects[$Matches[1]].ScopedUsers | ForEach-Object { $script:FakeUsers[$_] }) } }
  @{ P = "$($graph)groups\?scopeDescriptor=scp\.(p\d)"; B = {
      Get-FakeValue @($script:FakeProjects[$Matches[1]].ScopedGroups | ForEach-Object { Get-FakeGroupSubject $_ }) } }
  @{ P = "$($graph)memberships/([^?]+)\?direction=down"; B = {
      $members = $script:FakeGroups[$Matches[1]].Members
      if ($null -eq $members) { throw (New-FakeHttpError 403 'Access denied to group membership.') }
      Get-FakeValue @($members | ForEach-Object { @{ memberDescriptor = $_ } }) } }
  @{ P = "$($graph)users/([^?]+)\?"; B = {
      if (-not $script:FakeUsers.ContainsKey($Matches[1])) { throw (New-FakeHttpError 404 'User not found.') }
      $script:FakeUsers[$Matches[1]] } }
  @{ P = "$($graph)groups/([^?]+)\?"; B = {
      if (-not $script:FakeGroups.ContainsKey($Matches[1])) { throw (New-FakeHttpError 404 'Group not found.') }
      Get-FakeGroupSubject $Matches[1] } }

  @{ P = '^https://analytics\.dev\.azure\.com/contoso/(\w+)/_odata/v4\.0-preview/WorkItems\?\$apply='; B = {
      $p = $script:FakeProjects.Values | Where-Object { $_.Detail.name -eq $Matches[1] }
      Get-FakeValue $p.WorkItemCounts } }
  @{ P = '^https://analytics\.dev\.azure\.com/contoso/(\w+)/_odata/v4\.0-preview/WorkItems\?\$select=ChangedDate'; B = {
      $p = $script:FakeProjects.Values | Where-Object { $_.Detail.name -eq $Matches[1] }
      Get-FakeValue @(@{ ChangedDate = $p.LastChanged }) } }

  @{ P = "$core(p\d)/_apis/wit/workitemtypes\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].WorkItemTypes } }
  @{ P = "$core(p\d)/_apis/wit/classificationnodes\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Nodes } }
  @{ P = "$core(p\d)/_apis/git/repositories\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Repos } }
  @{ P = "$core(p\d)/_apis/git/repositories/(r\d)/commits\?"; B = { Get-FakeValue $script:FakeCommits[$Matches[2]] } }
  @{ P = "$core(p\d)/_apis/git/repositories/(r\d)/refs\?"; B = { Get-FakeValue $script:FakeRefs[$Matches[2]] } }
  @{ P = "$core(p\d)/_apis/tfvc/items\?"; B = {
      $tfvc = $script:FakeProjects[$Matches[1]].Tfvc
      if ($null -eq $tfvc) { throw (New-FakeHttpError 404 'TF10158: The item $/ does not exist.') }
      Get-FakeValue $tfvc } }
  @{ P = "$core(p\d)/_apis/build/definitions\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Builds } }
  @{ P = '^https://vsrm\.dev\.azure\.com/contoso/(p\d)/_apis/release/definitions\?'; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Releases } }
  @{ P = '^https://feeds\.dev\.azure\.com/contoso/_apis/packaging/feeds\?'; B = {
      Get-FakeValue @(
        @{ id = 'f1'; name = 'contoso-packages'; project = @{ id = 'p1' }; upstreamEnabled = $true },
        @{ id = 'f0'; name = 'org-feed'; upstreamEnabled = $false }) } }
  @{ P = '^https://feeds\.dev\.azure\.com/contoso/(p\d)/_apis/packaging/feeds/(f\d)/packages\?'; B = {
      Get-FakeValue @(@{ protocolType = 'npm' }, @{ protocolType = 'NuGet' }, @{ protocolType = 'npm' }) } }
  @{ P = "$core(p\d)/_apis/wiki/wikis\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Wikis } }
  @{ P = "$core(p\d)/_apis/testplan/plans\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].TestPlans } }
  @{ P = "$core(p\d)/_apis/serviceendpoint/endpoints\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Endpoints } }
  @{ P = "$core(p\d)/_apis/distributedtask/queues\?"; B = { Get-FakeValue $script:FakeProjects[$Matches[1]].Queues } }
)

function Reset-FakeAdo {
  $script:FakeRequests = New-Object System.Collections.Generic.List[object]
  $script:FakeUnrouted = New-Object System.Collections.Generic.List[string]
}

function Invoke-FakeAdo {
  <#
  .SYNOPSIS
    Stands in for Invoke-WebRequest. Records every request, then answers from the fake
    organization. A URL with no route is recorded as unrouted and fails with a 404.
  #>
  param([string]$Uri, [hashtable]$Headers, [string]$Method)
  $script:FakeRequests.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Authorization = $Headers.Authorization })
  foreach ($route in $script:FakeRoutes) {
    if ($Uri -match $route.P) { return (New-FakeResponse (& $route.B)) }
  }
  $script:FakeUnrouted.Add($Uri)
  throw (New-FakeHttpError 404 "No fake route for $Uri")
}

Reset-FakeAdo
