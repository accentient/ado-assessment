function Main {
  clear-host

  # The organization to assess, and the Windows Credential Manager entry that holds its PAT.
  $script:AdoOrgUrl = "https://dev.azure.com/YOUR-ORG/"
  $script:AdoCredentialName = "YOUR-ORG-assessment-PAT"
  $script:ReportFolder = Join-Path (Split-Path $PSScriptRoot -Parent) "reports"

  # One-time helpers. Uncomment, run once, comment out again.
  # Save-AdoPat            # prompts securely and stores the PAT for this organization
  # Test-AdoConnection     # confirms the PAT works and lists the projects it can see

  # Pick one. The results stay in $Assessment after the run so you can explore them.
  # $script:Assessment = AssessProjects -Projects 'Project A', 'Project B'
  # $script:Assessment = AssessProjects -CsvPath (Join-Path (Split-Path $PSScriptRoot -Parent) "projects.csv")

  $script:Assessment = AssessProjects -All

  # $script:Assessment = AssessProjects -Projects 'Project A' -OutputPath "C:\Temp\assessment.md"
}

# API versions. 7.1 is current GA; a few services still require preview tags.
$script:ApiVersion       = "7.1"
$script:GraphApiVersion  = "7.1-preview.1"
$script:FeedsApiVersion  = "7.1-preview.1"
$script:MemApiVersion    = "7.1-preview.3"

# =============================================================================
# Windows Credential Manager access (CredRead / CredWrite / CredDelete)
# =============================================================================

if (-not ("AdoCredMan" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AdoCredMan
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;
    private const int ERROR_NOT_FOUND = 1168;

    public static string Read(string target)
    {
        IntPtr ptr;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out ptr))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND) return null;
            throw new System.ComponentModel.Win32Exception(err);
        }
        try
        {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (cred.CredentialBlobSize == 0) return string.Empty;
            return Marshal.PtrToStringUni(cred.CredentialBlob, (int)cred.CredentialBlobSize / 2);
        }
        finally
        {
            CredFree(ptr);
        }
    }

    public static void Write(string target, string userName, string secret)
    {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        CREDENTIAL cred = new CREDENTIAL();
        cred.Type = CRED_TYPE_GENERIC;
        cred.TargetName = target;
        cred.UserName = userName;
        cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
        cred.CredentialBlobSize = (uint)blob.Length;
        cred.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, cred.CredentialBlob, blob.Length);
            if (!CredWrite(ref cred, 0))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeHGlobal(cred.CredentialBlob);
        }
    }

    public static bool Delete(string target)
    {
        if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
        int err = Marshal.GetLastWin32Error();
        if (err == ERROR_NOT_FOUND) return false;
        throw new System.ComponentModel.Win32Exception(err);
    }
}
"@
}

function Get-AdoOrgName {
  <#
  .SYNOPSIS
    Parses the organization name out of $script:AdoOrgUrl.
  #>
  $url = [string]$script:AdoOrgUrl
  if ([string]::IsNullOrWhiteSpace($url) -or $url -match 'YOUR-ORG') {
    throw "Set `$script:AdoOrgUrl in the Main function of AssessProjects.ps1 to your organization URL."
  }
  $url = $url.Trim()
  if (-not $url.EndsWith('/')) { $url += '/' }
  if ($url -match '^https://dev\.azure\.com/([^/]+)/$') { return $Matches[1] }
  if ($url -match '^https://([^./]+)\.visualstudio\.com/$') { return $Matches[1] }
  throw "Unrecognized organization URL '$url'. Expected https://dev.azure.com/{org}/ or https://{org}.visualstudio.com/"
}

function Get-AdoCredentialName {
  if ([string]::IsNullOrWhiteSpace($script:AdoCredentialName)) {
    throw "Set `$script:AdoCredentialName in the Main function of AssessProjects.ps1 to the Credential Manager entry that holds the PAT."
  }
  return $script:AdoCredentialName
}

function Save-AdoPat {
  <#
  .SYNOPSIS
    Stores the PAT in Windows Credential Manager under $script:AdoCredentialName.
    Prompts securely; the token is never echoed or written to disk in clear text.
  #>
  param(
    [string]$Target = (Get-AdoCredentialName)
  )
  $secure = Read-Host -Prompt "Paste the Azure DevOps PAT for '$Target'" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
  if ([string]::IsNullOrWhiteSpace($plain)) {
    throw "No PAT entered. Nothing saved."
  }
  [AdoCredMan]::Write($Target, "pat", $plain.Trim())
  $plain = $null
  Write-Host "PAT saved to Windows Credential Manager as '$Target'." -ForegroundColor Green
}

function Remove-AdoPat {
  <#
  .SYNOPSIS
    Removes the stored PAT from Windows Credential Manager.
  #>
  param(
    [string]$Target = (Get-AdoCredentialName)
  )
  if ([AdoCredMan]::Delete($Target)) {
    Write-Host "Removed credential '$Target'." -ForegroundColor Green
  } else {
    Write-Host "No credential named '$Target' was found." -ForegroundColor Yellow
  }
}

function Get-AdoPat {
  $target = Get-AdoCredentialName
  $pat = [AdoCredMan]::Read($target)
  if ([string]::IsNullOrWhiteSpace($pat)) {
    throw ("No PAT found. Add a Windows credential named '$target' (see README.md) " +
           "or run Save-AdoPat once to store it.")
  }
  return $pat.Trim()
}

# =============================================================================
# Connection
# =============================================================================

function Connect-Ado {
  <#
  .SYNOPSIS
    Resolves the organization URLs and builds the auth header. Called
    automatically; you normally do not need to call it yourself.
  #>
  $org = Get-AdoOrgName

  $script:Org           = $org
  $script:CoreBase      = "https://dev.azure.com/$org/"
  $script:GraphBase     = "https://vssps.dev.azure.com/$org/"
  $script:FeedsBase     = "https://feeds.dev.azure.com/$org/"
  $script:ReleaseBase   = "https://vsrm.dev.azure.com/$org/"
  $script:AnalyticsBase = "https://analytics.dev.azure.com/$org/"
  $script:MemBase       = "https://vsaex.dev.azure.com/$org/"

  $pat = Get-AdoPat
  $bytes = [Text.Encoding]::ASCII.GetBytes(":" + $pat)
  $script:AdoHeaders = @{
    Authorization = "Basic " + [Convert]::ToBase64String($bytes)
    Accept        = "application/json"
  }
  $pat = $null
  $script:Connected = $true
}

function Test-AdoConnection {
  <#
  .SYNOPSIS
    Confirms the PAT authenticates and shows the identity it resolves to.
  #>
  Connect-Ado
  $data = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/connectionData?api-version=$($script:ApiVersion)-preview.1")
  $user = $data.authenticatedUser
  $account = $null
  try { $account = $user.properties.Account.'$value' } catch { }
  if (-not $account) { $account = $user.id }
  Write-Host ("Connected to {0} as {1} ({2})" -f $script:Org, $user.providerDisplayName, $account) -ForegroundColor Green
  $projects = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/projects?api-version=$($script:ApiVersion)") -AllPages
  Write-Host ("{0} project(s) visible: {1}" -f @($projects).Count, (($projects | Sort-Object name | ForEach-Object { $_.name }) -join ", "))
}

# =============================================================================
# HTTP: the ONLY function that talks to Azure DevOps. GET is hard-coded.
# =============================================================================

function Invoke-AdoGet {
  <#
  .SYNOPSIS
    Issues an HTTP GET and returns the parsed JSON body.
    -AllPages follows x-ms-continuationtoken headers and OData nextLink and
    returns the concatenated "value" arrays.
    -Raw returns the response body as text (used for OData $count).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [switch]$AllPages,
    [switch]$Raw
  )

  if (-not $script:Connected) { Connect-Ado }

  $collected = New-Object System.Collections.Generic.List[object]
  $nextUri = $Uri
  $guard = 0

  while ($nextUri) {
    $guard++
    if ($guard -gt 500) { throw "Paging guard tripped for $Uri" }

    # The verb below is the only verb this script ever uses.
    try {
      $response = Invoke-WebRequest -Uri $nextUri -Headers $script:AdoHeaders -Method Get -UseBasicParsing -ErrorAction Stop
    } catch {
      # Some endpoints still require "-preview" on the api-version. Azure DevOps says
      # so explicitly; when it does, retry once with the preview tag appended.
      $bodyText = Get-AdoErrorBody $_
      if ($bodyText -like '*VssInvalidPreviewVersionException*' -and $nextUri -match 'api-version=([\d.]+)(&|$)') {
        $retryUri = $nextUri -replace 'api-version=([\d.]+)(&|$)', 'api-version=$1-preview$2'
        Write-Verbose "Retrying with preview api-version: $retryUri"
        $response = Invoke-WebRequest -Uri $retryUri -Headers $script:AdoHeaders -Method Get -UseBasicParsing -ErrorAction Stop
      } else {
        throw
      }
    }

    $contentType = ""
    foreach ($k in $response.Headers.Keys) {
      if ($k -ieq 'Content-Type') { $contentType = [string](@($response.Headers[$k])[0]) }
    }
    if ($contentType -like 'text/html*') {
      throw "Azure DevOps returned an HTML sign-in page instead of JSON. The PAT is missing, expired, or lacks access. ($nextUri)"
    }

    if ($Raw) { return $response.Content }

    $body = ConvertFrom-AdoJson $response.Content
    if (-not $AllPages) { return $body }

    if ($null -ne $body.PSObject.Properties['value']) {
      foreach ($item in @($body.value)) { $collected.Add($item) }
    } elseif ($null -ne $body.PSObject.Properties['members']) {
      foreach ($item in @($body.members)) { $collected.Add($item) }
    } else {
      $collected.Add($body)
    }

    $nextUri = $null

    # Continuation token in a response header (Core, Graph, Build, Test Plans)
    $token = $null
    foreach ($k in $response.Headers.Keys) {
      if ($k -ieq 'x-ms-continuationtoken') { $token = [string](@($response.Headers[$k])[0]) }
    }
    # Continuation token in the body (Member Entitlement Management)
    if (-not $token -and $null -ne $body.PSObject.Properties['continuationToken'] -and $body.continuationToken) {
      $token = [string]$body.continuationToken
    }
    if ($token) {
      $sep = '&'
      if ($Uri -notlike '*?*') { $sep = '?' }
      $nextUri = $Uri + $sep + "continuationToken=" + [uri]::EscapeDataString($token)
    }
    # OData nextLink (Analytics)
    if ($null -ne $body.PSObject.Properties['@odata.nextLink'] -and $body.'@odata.nextLink') {
      $nextUri = [string]$body.'@odata.nextLink'
    }
  }

  return ,$collected.ToArray()
}

function Get-AdoErrorBody($ErrorRecord) {
  # Returns the response body text from a failed Invoke-WebRequest, on both
  # PowerShell 7 (ErrorDetails) and Windows PowerShell 5.1 (response stream).
  try {
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { return [string]$ErrorRecord.ErrorDetails.Message }
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and ($resp -is [System.Net.HttpWebResponse])) {
      $stream = $resp.GetResponseStream()
      if ($stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        return $text
      }
    }
  } catch { }
  return [string]$ErrorRecord.Exception.Message
}

function ConvertFrom-AdoJson([string]$Content) {
  # Some payloads (work item types) carry a property whose name is an empty
  # string, which PowerShell 7's parser refuses. Rename it and retry.
  try {
    return ($Content | ConvertFrom-Json)
  } catch {
    $patched = $Content -replace '"\s*"\s*:', '"_empty_":'
    return ($patched | ConvertFrom-Json)
  }
}

function Get-AdoSkipPaged {
  <#
  .SYNOPSIS
    Pages endpoints that only support $top/$skip (teams, team members).
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$PageSize = 200
  )
  $all = New-Object System.Collections.Generic.List[object]
  $skip = 0
  $sep = '&'
  if ($Uri -notlike '*?*') { $sep = '?' }
  do {
    $page = Invoke-AdoGet -Uri ($Uri + $sep + "`$top=$PageSize&`$skip=$skip")
    $items = @()
    if ($null -ne $page.PSObject.Properties['value']) { $items = @($page.value) }
    foreach ($i in $items) { $all.Add($i) }
    $skip += $PageSize
  } while ($items.Count -eq $PageSize)
  return ,$all.ToArray()
}

# =============================================================================
# Error tolerant collection
# =============================================================================

function Invoke-Collector {
  <#
  .SYNOPSIS
    Runs a collector script block. On failure, records a readable message on the
    project (including which PAT scope is probably missing) and returns $null so
    one denied API does not abort the whole assessment.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Scope,
    [Parameter(Mandatory = $true)][scriptblock]$Script,
    [Parameter(Mandatory = $true)]$Project
  )
  try {
    return (& $Script)
  } catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    $msg = $_.Exception.Message
    $serverMsg = $null
    try {
      $parsed = ConvertFrom-Json (Get-AdoErrorBody $_)
      if ($parsed.message) { $serverMsg = [string]$parsed.message }
      elseif ($parsed.error -and $parsed.error.message) { $serverMsg = [string]$parsed.error.message }
    } catch { }
    if ($status -eq 401) {
      $msg = "HTTP 401 (unauthorized). The PAT is missing, expired, or lacks the '$Scope' scope."
    } elseif ($status -eq 403) {
      $msg = "HTTP 403 (forbidden). Either the PAT lacks the '$Scope' scope, or your account lacks the permission or license for this area."
    } elseif ($status) {
      $msg = "HTTP $status. $msg"
    }
    if ($serverMsg) { $msg += " Server said: $serverMsg" }
    $Project.Errors.Add("$Name`: $msg")
    Write-Host "    ! $Name`: $msg" -ForegroundColor Yellow
    return $null
  }
}

# =============================================================================
# Organization level lookups (cached for the run)
# =============================================================================

function Get-AdoAllProjects {
  if (-not $script:ProjectCache) {
    $script:ProjectCache = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/projects?`$top=1000&api-version=$($script:ApiVersion)") -AllPages
  }
  return $script:ProjectCache
}

function Get-AdoProcessMap {
  # Maps process typeId -> @{ Name; Parent; IsInherited }
  if (-not $script:ProcessMap) {
    $map = @{}
    try {
      $procs = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/work/processes?api-version=$($script:ApiVersion)") -AllPages
      foreach ($p in $procs) { $map[[string]$p.typeId] = $p }
      foreach ($p in $procs) {
        $parentName = $null
        if ($p.parentProcessTypeId -and $map.ContainsKey([string]$p.parentProcessTypeId)) {
          $parentName = $map[[string]$p.parentProcessTypeId].name
        }
        $p | Add-Member -NotePropertyName ParentName -NotePropertyValue $parentName -Force
      }
    } catch {
      Write-Host "  ! Could not read the process list (needs 'Work Items (Read)'). Inherited process parents will not be shown." -ForegroundColor Yellow
    }
    $script:ProcessMap = $map
  }
  return $script:ProcessMap
}

function Get-AdoEntitlementMap {
  # Maps user descriptor -> @{ AccessLevel; LastAccessed; DateCreated }
  if ($null -eq $script:EntitlementMap) {
    $map = @{}
    try {
      $uri = $script:MemBase + "_apis/userentitlements?`$top=10000&api-version=$($script:MemApiVersion)"
      $members = Invoke-AdoGet -Uri $uri -AllPages
      foreach ($m in $members) {
        if ($m.user -and $m.user.descriptor) {
          $map[[string]$m.user.descriptor] = [pscustomobject]@{
            AccessLevel  = $m.accessLevel.licenseDisplayName
            LastAccessed = $m.lastAccessedDate
            DateCreated  = $m.dateCreated
          }
        }
      }
      Write-Host ("  Loaded {0} user entitlement(s) for access levels." -f $map.Count)
    } catch {
      Write-Host "  ! Could not read user entitlements (needs 'Member Entitlement Management (Read)'). Access levels will show as n/a." -ForegroundColor Yellow
    }
    $script:EntitlementMap = $map
  }
  return $script:EntitlementMap
}

function Get-AdoAllFeeds {
  if ($null -eq $script:FeedCache) {
    try {
      $script:FeedCache = @(Invoke-AdoGet -Uri ($script:FeedsBase + "_apis/packaging/feeds?api-version=$($script:FeedsApiVersion)") -AllPages)
    } catch {
      $script:FeedCache = $null
      throw
    }
  }
  return $script:FeedCache
}

# =============================================================================
# Graph (identity) helpers
# =============================================================================

$script:SubjectCache = @{}   # descriptor -> subject object (user or group)

function Test-IsGroupDescriptor([string]$Descriptor) {
  return ($Descriptor -like 'vssgp.*' -or $Descriptor -like 'aadgp.*')
}

function Get-SubjectKind([string]$Descriptor) {
  if ($Descriptor -like 'vssgp.*') { return 'ADO group' }
  if ($Descriptor -like 'aadgp.*') { return 'Entra group' }
  if ($Descriptor -like 'aad.*')   { return 'User' }
  if ($Descriptor -like 'msa.*')   { return 'User (MSA)' }
  if ($Descriptor -like 'aadsp.*') { return 'Service principal' }
  if ($Descriptor -like 'svc.*')   { return 'Service account' }
  if ($Descriptor -like 'bnd.*')   { return 'User (invite pending)' }
  return 'Other'
}

function Add-SubjectToCache($Subject) {
  if ($Subject -and $Subject.descriptor) {
    $script:SubjectCache[[string]$Subject.descriptor] = $Subject
  }
}

function Get-AdoSubject([string]$Descriptor) {
  if ($script:SubjectCache.ContainsKey($Descriptor)) { return $script:SubjectCache[$Descriptor] }
  $subject = $null
  try {
    if (Test-IsGroupDescriptor $Descriptor) {
      $subject = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/groups/$Descriptor`?api-version=$($script:GraphApiVersion)")
    } else {
      $subject = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/users/$Descriptor`?api-version=$($script:GraphApiVersion)")
    }
  } catch {
    $subject = [pscustomobject]@{ descriptor = $Descriptor; displayName = "(unresolved $Descriptor)"; principalName = ""; mailAddress = "" }
  }
  Add-SubjectToCache $subject
  return $subject
}

function Get-AdoScopeDescriptor([string]$ProjectId) {
  $r = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/descriptors/$ProjectId`?api-version=$($script:GraphApiVersion)")
  return [string]$r.value
}

function Expand-AdoGroup {
  <#
  .SYNOPSIS
    Recursively expands a group descriptor into the set of non-group members
    (users, service principals, service accounts). Returns a hashtable:
      Users  = HashSet of member descriptors
      Groups = list of nested group descriptors that were expanded
      Unexpanded = nested groups that could not be expanded (permissions or Entra)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Descriptor,
    [hashtable]$Cache = $null
  )
  if ($null -eq $Cache) { $Cache = $script:ExpandCache }
  if ($Cache.ContainsKey($Descriptor)) { return $Cache[$Descriptor] }

  $users = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $groups = New-Object System.Collections.Generic.List[string]
  $unexpanded = New-Object System.Collections.Generic.List[string]
  $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($Descriptor)
  [void]$visited.Add($Descriptor)

  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $memberships = $null
    try {
      $memberships = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/memberships/$current`?direction=down&api-version=$($script:GraphApiVersion)") -AllPages
    } catch {
      if ($current -ne $Descriptor) { $unexpanded.Add($current) }
      continue
    }
    foreach ($m in @($memberships)) {
      $d = [string]$m.memberDescriptor
      if (-not $d) { continue }
      if (Test-IsGroupDescriptor $d) {
        if ($visited.Add($d)) {
          $groups.Add($d)
          $queue.Enqueue($d)
        }
      } else {
        [void]$users.Add($d)
      }
    }
  }

  $result = @{ Users = $users; Groups = $groups; Unexpanded = $unexpanded }
  $Cache[$Descriptor] = $result
  return $result
}

# =============================================================================
# Per project collectors
# =============================================================================

function Get-ProjectCore($ProjectRef) {
  $detail = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/projects/$($ProjectRef.id)?includeCapabilities=true&api-version=$($script:ApiVersion)")
  $processMap = Get-AdoProcessMap
  $templateName = $null
  $templateTypeId = $null
  $sourceControl = $null
  if ($detail.capabilities) {
    if ($detail.capabilities.processTemplate) {
      $templateName = $detail.capabilities.processTemplate.templateName
      $templateTypeId = [string]$detail.capabilities.processTemplate.templateTypeId
    }
    if ($detail.capabilities.versioncontrol) {
      $sourceControl = $detail.capabilities.versioncontrol.sourceControlType
    }
  }
  $processDisplay = $templateName
  $processParent = $null
  if ($templateTypeId -and $processMap.ContainsKey($templateTypeId)) {
    $p = $processMap[$templateTypeId]
    $processDisplay = $p.name
    if ($p.ParentName) { $processParent = $p.ParentName }
  }
  return [pscustomobject]@{
    Description    = $detail.description
    State          = (ConvertTo-ProjectStateText $detail.state)
    Visibility     = $detail.visibility
    LastUpdateTime = $detail.lastUpdateTime
    Process        = $processDisplay
    ProcessParent  = $processParent
    SourceControl  = $sourceControl
    Url            = "https://dev.azure.com/$($script:Org)/" + [uri]::EscapeDataString($ProjectRef.name)
  }
}

function Get-ProjectSecurity($ProjectRef, $Project) {
  <#
    Returns the project's security groups with expanded membership, the teams
    with rosters, and a merged people table.
  #>
  $scope = Get-AdoScopeDescriptor $ProjectRef.id

  # Seed the subject cache with everything in project scope (cheap, two calls)
  $scopedUsers = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/users?scopeDescriptor=$scope&api-version=$($script:GraphApiVersion)") -AllPages
  foreach ($u in @($scopedUsers)) { Add-SubjectToCache $u }
  $scopedGroups = Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/groups?scopeDescriptor=$scope&api-version=$($script:GraphApiVersion)") -AllPages
  foreach ($g in @($scopedGroups)) { Add-SubjectToCache $g }

  # Expand every project level group
  $groupRows = New-Object System.Collections.Generic.List[object]
  $groupMembers = @{}   # group display name -> HashSet of user descriptors
  foreach ($g in @($scopedGroups)) {
    $name = [string]$g.displayName
    $exp = Expand-AdoGroup -Descriptor ([string]$g.descriptor)
    $groupMembers[$name] = $exp.Users
    $groupRows.Add([pscustomobject]@{
      Name        = $name
      Descriptor  = [string]$g.descriptor
      Description = [string]$g.description
      People      = $exp.Users.Count
      NestedGroups = $exp.Groups.Count
      Unexpanded  = @($exp.Unexpanded | ForEach-Object { (Get-AdoSubject $_).displayName })
    })
  }

  # Teams
  $teamList = Get-AdoSkipPaged -Uri ($script:CoreBase + "_apis/projects/$($ProjectRef.id)/teams?api-version=$($script:ApiVersion)")
  $defaultTeamId = $null
  if ($ProjectRef.defaultTeam) { $defaultTeamId = [string]$ProjectRef.defaultTeam.id }
  else {
    try {
      $pd = Invoke-AdoGet -Uri ($script:CoreBase + "_apis/projects/$($ProjectRef.id)?api-version=$($script:ApiVersion)")
      if ($pd.defaultTeam) { $defaultTeamId = [string]$pd.defaultTeam.id }
    } catch { }
  }

  $adminSet = $groupMembers['Project Administrators']
  $contribSet = $groupMembers['Contributors']
  $readerSet = $groupMembers['Readers']
  $emptySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  if (-not $adminSet) { $adminSet = $emptySet }
  if (-not $contribSet) { $contribSet = $emptySet }
  if (-not $readerSet) { $readerSet = $emptySet }

  $teams = New-Object System.Collections.Generic.List[object]
  $teamsByUser = @{}   # user descriptor -> list of team names
  foreach ($t in @($teamList | Sort-Object name)) {
    $teamDescriptor = $null
    $roster = $null
    try {
      $teamDescriptor = [string](Invoke-AdoGet -Uri ($script:GraphBase + "_apis/graph/descriptors/$($t.id)?api-version=$($script:GraphApiVersion)")).value
      $roster = Expand-AdoGroup -Descriptor $teamDescriptor
    } catch {
      $Project.Errors.Add("Team '$($t.name)': could not expand membership via Graph. $($_.Exception.Message)")
    }

    $teamAdmins = New-Object System.Collections.Generic.List[string]
    $directMembers = @()
    try {
      $directMembers = Get-AdoSkipPaged -Uri ($script:CoreBase + "_apis/projects/$($ProjectRef.id)/teams/$($t.id)/members?api-version=$($script:ApiVersion)")
      foreach ($m in $directMembers) {
        if ($m.isTeamAdmin -and $m.identity) { $teamAdmins.Add([string]$m.identity.displayName) }
      }
    } catch {
      $Project.Errors.Add("Team '$($t.name)': could not read members. $($_.Exception.Message)")
    }

    $members = New-Object System.Collections.Generic.List[object]
    $userDescriptors = @()
    if ($roster) { $userDescriptors = @($roster.Users) }
    elseif ($directMembers) { $userDescriptors = @($directMembers | Where-Object { $_.identity -and $_.identity.descriptor -and -not $_.identity.isContainer } | ForEach-Object { [string]$_.identity.descriptor }) }

    foreach ($d in $userDescriptors) {
      $s = Get-AdoSubject $d
      $members.Add([pscustomobject]@{
        Descriptor  = $d
        DisplayName = [string]$s.displayName
        Email       = [string](Coalesce $s.mailAddress $s.principalName)
        Kind        = Get-SubjectKind $d
      })
      if (-not $teamsByUser.ContainsKey($d)) { $teamsByUser[$d] = New-Object System.Collections.Generic.List[string] }
      $teamsByUser[$d].Add([string]$t.name)
    }

    $contribCount = @($userDescriptors | Where-Object { $contribSet.Contains($_) }).Count
    $readerCount  = @($userDescriptors | Where-Object { $readerSet.Contains($_) }).Count
    $adminCount   = @($userDescriptors | Where-Object { $adminSet.Contains($_) }).Count
    $nestedGroups = @()
    $unexpanded = @()
    if ($roster) {
      $nestedGroups = @($roster.Groups | ForEach-Object { (Get-AdoSubject $_).displayName })
      $unexpanded = @($roster.Unexpanded | ForEach-Object { (Get-AdoSubject $_).displayName })
    }

    $teams.Add([pscustomobject]@{
      Name          = [string]$t.name
      Id            = [string]$t.id
      Description   = [string]$t.description
      IsDefault     = ($defaultTeamId -and ([string]$t.id -eq $defaultTeamId))
      People        = $members.Count
      Contributors  = $contribCount
      Readers       = $readerCount
      ProjectAdmins = $adminCount
      TeamAdmins    = @($teamAdmins)
      NestedGroups  = $nestedGroups
      Unexpanded    = $unexpanded
      Members       = @($members | Sort-Object DisplayName)
    })
  }

  # People table: everyone with any membership in the project
  $validUsers = $groupMembers['Project Valid Users']
  $allDescriptors = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  if ($validUsers) { foreach ($d in $validUsers) { [void]$allDescriptors.Add($d) } }
  foreach ($set in $groupMembers.Values) { foreach ($d in $set) { [void]$allDescriptors.Add($d) } }
  foreach ($d in $teamsByUser.Keys) { [void]$allDescriptors.Add($d) }

  $entitlements = Get-AdoEntitlementMap
  $people = New-Object System.Collections.Generic.List[object]
  foreach ($d in $allDescriptors) {
    $s = Get-AdoSubject $d
    $roles = New-Object System.Collections.Generic.List[string]
    if ($adminSet.Contains($d)) { $roles.Add('Project Admin') }
    if ($contribSet.Contains($d)) { $roles.Add('Contributor') }
    if ($readerSet.Contains($d)) { $roles.Add('Reader') }
    $otherGroups = @($groupMembers.Keys | Where-Object {
        $_ -notin @('Project Administrators', 'Contributors', 'Readers', 'Project Valid Users') -and
        $groupMembers[$_].Contains($d) -and
        -not ($teamsByUser.ContainsKey($d) -and $teamsByUser[$d] -contains $_)
      } | Sort-Object)
    $teamNames = @()
    if ($teamsByUser.ContainsKey($d)) { $teamNames = @($teamsByUser[$d] | Sort-Object) }
    $ent = $null
    if ($entitlements.ContainsKey($d)) { $ent = $entitlements[$d] }
    $people.Add([pscustomobject]@{
      Descriptor   = $d
      DisplayName  = [string]$s.displayName
      Email        = [string](Coalesce $s.mailAddress $s.principalName)
      Kind         = Get-SubjectKind $d
      AccessLevel  = $(if ($ent) { [string]$ent.AccessLevel } else { $null })
      LastAccessed = $(if ($ent) { $ent.LastAccessed } else { $null })
      Roles        = @($roles)
      OtherGroups  = $otherGroups
      Teams        = $teamNames
    })
  }

  return [pscustomobject]@{
    ScopeDescriptor = $scope
    Groups          = @($groupRows | Sort-Object Name)
    Teams = $teams.ToArray()
    People          = @($people | Sort-Object DisplayName)
    Counts          = [pscustomobject]@{
      People        = $allDescriptors.Count
      ProjectAdmins = $adminSet.Count
      Contributors  = $contribSet.Count
      Readers       = $readerSet.Count
      Teams         = $teams.Count
    }
  }
}

function Get-ProjectWorkItems($ProjectRef, $Project) {
  $types = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/wit/workitemtypes?api-version=$($script:ApiVersion)")
  $typeRows = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($types.value | Sort-Object name)) {
    $typeRows.Add([pscustomobject]@{
      Name       = [string]$t.name
      Reference  = [string]$t.referenceName
      IsDisabled = [bool]$t.isDisabled
      Count      = $null
    })
  }

  # Counts per type and last change come from Analytics (separate scope)
  $counts = Invoke-Collector -Name 'Work item counts (Analytics)' -Scope 'Analytics (Read)' -Project $Project -Script {
    $encoded = [uri]::EscapeDataString($ProjectRef.name)
    $uri = $script:AnalyticsBase + "$encoded/_odata/v4.0-preview/WorkItems?`$apply=groupby((WorkItemType),aggregate(`$count as Count))"
    $byType = Invoke-AdoGet -Uri $uri -AllPages
    $last = Invoke-AdoGet -Uri ($script:AnalyticsBase + "$encoded/_odata/v4.0-preview/WorkItems?`$select=ChangedDate&`$orderby=ChangedDate desc&`$top=1")
    $lastChanged = $null
    if ($last.value -and @($last.value).Count -gt 0) { $lastChanged = @($last.value)[0].ChangedDate }
    [pscustomobject]@{ ByType = @($byType); LastChanged = $lastChanged }
  }

  $total = $null
  $lastChanged = $null
  if ($counts) {
    $total = 0
    foreach ($row in $counts.ByType) {
      $total += [int]$row.Count
      $match = $typeRows | Where-Object { $_.Name -eq [string]$row.WorkItemType }
      if ($match) { $match.Count = [int]$row.Count }
      else {
        $typeRows.Add([pscustomobject]@{ Name = [string]$row.WorkItemType; Reference = ''; IsDisabled = $true; Count = [int]$row.Count })
      }
    }
    foreach ($r in $typeRows) { if ($null -eq $r.Count) { $r.Count = 0 } }
    $lastChanged = $counts.LastChanged
  }

  # Area and iteration paths
  $areaCount = $null; $iterationCount = $null
  try {
    $nodes = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/wit/classificationnodes?`$depth=50&api-version=$($script:ApiVersion)")
    foreach ($n in @($nodes.value)) {
      $c = Measure-ClassificationNodes $n
      if ($n.structureType -eq 'area') { $areaCount = $c }
      elseif ($n.structureType -eq 'iteration') { $iterationCount = $c }
    }
  } catch {
    $Project.Errors.Add("Area/iteration paths: $($_.Exception.Message)")
  }

  return [pscustomobject]@{
    Types = $typeRows.ToArray()
    TypeCount      = @($typeRows | Where-Object { -not $_.IsDisabled }).Count
    DisabledTypes  = @($typeRows | Where-Object { $_.IsDisabled } | ForEach-Object { $_.Name })
    Total          = $total
    LastChanged    = $lastChanged
    AreaPaths      = $areaCount
    IterationPaths = $iterationCount
  }
}

function ConvertTo-ProjectStateText([string]$State) {
  switch ($State) {
    'wellFormed'    { return 'Active' }
    'createPending' { return 'Being created' }
    'new'           { return 'New, not yet fully created' }
    'deleting'      { return 'Being deleted' }
    'deleted'       { return 'Deleted' }
    'unchanged'     { return 'Unchanged' }
    default         { return $State }
  }
}

function Measure-ClassificationNodes($Node) {
  $count = 1
  if ($Node.children) {
    foreach ($c in @($Node.children)) { $count += Measure-ClassificationNodes $c }
  }
  return $count
}

function Get-ProjectRepos($ProjectRef, $Project) {
  $repos = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/git/repositories?api-version=$($script:ApiVersion)")
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($repos.value | Sort-Object name)) {
    $lastCommit = $null; $lastAuthor = $null; $branchCount = $null
    if (-not $r.isDisabled) {
      try {
        $commits = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/git/repositories/$($r.id)/commits?searchCriteria.`$top=1&api-version=$($script:ApiVersion)")
        if ($commits.value -and @($commits.value).Count -gt 0) {
          $lastCommit = @($commits.value)[0].committer.date
          $lastAuthor = @($commits.value)[0].author.name
        }
      } catch { }
      try {
        $refs = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/git/repositories/$($r.id)/refs?filter=heads/&api-version=$($script:ApiVersion)") -AllPages
        $branchCount = @($refs).Count
      } catch { }
    }
    $rows.Add([pscustomobject]@{
      Name          = [string]$r.name
      DefaultBranch = (([string]$r.defaultBranch) -replace '^refs/heads/', '')
      SizeMB        = $(if ($null -ne $r.size) { [math]::Round([double]$r.size / 1MB, 1) } else { $null })
      Branches      = $branchCount
      LastCommit    = $lastCommit
      LastAuthor    = $lastAuthor
      IsDisabled    = [bool]$r.isDisabled
      IsEmpty       = ($null -eq $lastCommit -and -not $r.isDisabled)
    })
  }

  $hasTfvc = $false
  try {
    $tfvc = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/tfvc/items?scopePath=" + [uri]::EscapeDataString('$/' + $ProjectRef.name) + "&recursionLevel=None&api-version=$($script:ApiVersion)")
    if ($tfvc.value -and @($tfvc.value).Count -gt 0) { $hasTfvc = $true }
  } catch { }

  return [pscustomobject]@{
    Repos = $rows.ToArray()
    Count      = $rows.Count
    Disabled   = @($rows | Where-Object { $_.IsDisabled }).Count
    Empty      = @($rows | Where-Object { $_.IsEmpty }).Count
    TotalSizeMB = [math]::Round((($rows | Measure-Object -Property SizeMB -Sum).Sum), 1)
    LastCommit = ($rows | Where-Object { $_.LastCommit } | Sort-Object { [datetime]$_.LastCommit } -Descending | Select-Object -First 1).LastCommit
    HasTfvc    = $hasTfvc
  }
}

function Get-ProjectPipelines($ProjectRef, $Project) {
  $defs = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/build/definitions?includeAllProperties=true&includeLatestBuilds=true&api-version=$($script:ApiVersion)") -AllPages
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($d in @($defs | Sort-Object name)) {
    $kind = 'Classic'
    if ($d.process -and [int]$d.process.type -eq 2) { $kind = 'YAML' }
    $lastRun = $null; $lastResult = $null
    $lb = $d.latestCompletedBuild
    if (-not $lb) { $lb = $d.latestBuild }
    if ($lb) {
      $lastRun = Coalesce $lb.finishTime $lb.queueTime
      $lastResult = Coalesce $lb.result $lb.status
    }
    $rows.Add([pscustomobject]@{
      Name       = [string]$d.name
      Path       = [string]$d.path
      Kind       = $kind
      Status     = [string]$d.queueStatus
      LastRun    = $lastRun
      LastResult = [string]$lastResult
      Repo       = $(if ($d.repository) { [string]$d.repository.name } else { $null })
    })
  }
  return [pscustomobject]@{
    Pipelines = $rows.ToArray()
    Count     = $rows.Count
    Yaml      = @($rows | Where-Object { $_.Kind -eq 'YAML' }).Count
    Classic   = @($rows | Where-Object { $_.Kind -eq 'Classic' }).Count
    Disabled  = @($rows | Where-Object { $_.Status -ne 'enabled' }).Count
    LastRun   = ($rows | Where-Object { $_.LastRun } | Sort-Object { [datetime]$_.LastRun } -Descending | Select-Object -First 1).LastRun
  }
}

function Get-ProjectReleases($ProjectRef, $Project) {
  $defs = Invoke-AdoGet -Uri ($script:ReleaseBase + "$($ProjectRef.id)/_apis/release/definitions?api-version=$($script:ApiVersion)") -AllPages
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($d in @($defs | Sort-Object name)) {
    $rows.Add([pscustomobject]@{
      Name = [string]$d.name
      Path = [string]$d.path
      LastModified = $d.modifiedOn
    })
  }
  return [pscustomobject]@{ Definitions = $rows.ToArray(); Count = $rows.Count }
}

function Get-ProjectFeeds($ProjectRef, $Project) {
  $all = Get-AdoAllFeeds
  $mine = @($all | Where-Object { $_.project -and ([string]$_.project.id -eq [string]$ProjectRef.id) })
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in ($mine | Sort-Object name)) {
    $packageCount = $null; $protocols = @()
    try {
      $pk = Invoke-AdoGet -Uri ($script:FeedsBase + "$($ProjectRef.id)/_apis/packaging/feeds/$($f.id)/packages?`$top=1000&api-version=$($script:FeedsApiVersion)")
      $packageCount = @($pk.value).Count
      $protocols = @($pk.value | ForEach-Object { $_.protocolType } | Sort-Object -Unique)
    } catch {
      $Project.Errors.Add("Feed '$($f.name)': could not list packages. $($_.Exception.Message)")
    }
    $rows.Add([pscustomobject]@{
      Name       = [string]$f.name
      Packages   = $packageCount
      Protocols  = $protocols
      UpstreamEnabled = [bool]$f.upstreamEnabled
    })
  }
  $packages = 0
  if ($rows.Count -gt 0) { $packages = ($rows | Measure-Object -Property Packages -Sum).Sum }
  return [pscustomobject]@{ Feeds = $rows.ToArray(); Count = $rows.Count; Packages = $packages }
}

function Get-ProjectExtras($ProjectRef, $Project) {
  $wikis = Invoke-Collector -Name 'Wikis' -Scope 'Wiki (Read)' -Project $Project -Script {
    $w = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/wiki/wikis?api-version=$($script:ApiVersion)")
    @($w.value | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Type = [string]$_.type } })
  }
  $testPlans = Invoke-Collector -Name 'Test plans' -Scope 'Test Management (Read)' -Project $Project -Script {
    @(Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/testplan/plans?api-version=$($script:ApiVersion)") -AllPages)
  }
  $endpoints = Invoke-Collector -Name 'Service connections' -Scope 'Service Connections (Read)' -Project $Project -Script {
    $e = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/serviceendpoint/endpoints?api-version=$($script:ApiVersion)")
    @($e.value | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Type = [string]$_.type; IsShared = [bool]$_.isShared } })
  }
  $queues = Invoke-Collector -Name 'Agent pools' -Scope 'Agent Pools (Read)' -Project $Project -Script {
    $q = Invoke-AdoGet -Uri ($script:CoreBase + "$($ProjectRef.id)/_apis/distributedtask/queues?api-version=$($script:ApiVersion)-preview.1")
    @($q.value | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; IsHosted = [bool]$_.pool.isHosted } })
  }
  # A collector that succeeds with nothing returns $null (PowerShell unrolls empty
  # arrays). Distinguish "empty" from "failed" by checking for a recorded warning.
  $failed = @($Project.Errors | ForEach-Object { ($_ -split ':')[0] })
  if ($null -eq $wikis -and 'Wikis' -notin $failed) { $wikis = @() }
  if ($null -eq $testPlans -and 'Test plans' -notin $failed) { $testPlans = @() }
  if ($null -eq $endpoints -and 'Service connections' -notin $failed) { $endpoints = @() }
  if ($null -eq $queues -and 'Agent pools' -notin $failed) { $queues = @() }
  return [pscustomobject]@{
    Wikis              = [object[]]$wikis
    TestPlans          = [object[]]$testPlans
    ServiceConnections = [object[]]$endpoints
    AgentQueues        = [object[]]$queues
  }
}

# =============================================================================
# Assessment entry point
# =============================================================================

function AssessProjects {
  <#
  .SYNOPSIS
    Assesses the given projects and writes a Markdown report and JSON dump.
  .PARAMETER Projects
    One or more project names.
  .PARAMETER CsvPath
    A text or CSV file with one project name per line (a header row named
    Project, Name or ProjectName is skipped; blank lines and # comments ignored).
  .PARAMETER All
    Assess every project the PAT can see.
  .PARAMETER OutputPath
    Markdown report path. Defaults to reports\ADO-Assessment-<timestamp>.md in the repository root.
    A .json file with the raw data is written next to it.
  .OUTPUTS
    The assessment objects, one per project, so you can inspect or pipe them.
  #>
  [CmdletBinding(DefaultParameterSetName = 'ByName')]
  param(
    [Parameter(ParameterSetName = 'ByName', Position = 0)][string[]]$Projects,
    [Parameter(ParameterSetName = 'ByCsv')][string]$CsvPath,
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [string]$OutputPath
  )

  Connect-Ado
  $script:ExpandCache = @{}
  $script:SubjectCache = @{}
  $script:ProjectCache = $null
  $script:FeedCache = $null
  $script:EntitlementMap = $null

  # Resolve requested names against the organization
  $available = @(Get-AdoAllProjects)
  $requested = @()
  switch ($PSCmdlet.ParameterSetName) {
    'ByCsv' {
      if (-not (Test-Path $CsvPath)) { throw "CSV file not found: $CsvPath" }
      $requested = @((Get-Content $CsvPath) -split '[\r\n,]' |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { $_ -and -not $_.StartsWith('#') -and $_ -notin @('Project', 'Name', 'ProjectName') })
    }
    'All'    { $requested = @($available | ForEach-Object { $_.name }) }
    default  {
      if (-not $Projects -or $Projects.Count -eq 0) { throw "Pass -Projects, -CsvPath, or -All." }
      $requested = @($Projects | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
  }
  $requested = @($requested | Select-Object -Unique)

  $targets = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($name in $requested) {
    $match = $available | Where-Object { $_.name -ieq $name } | Select-Object -First 1
    if ($match) { $targets.Add($match) } else { $missing.Add($name) }
  }
  if ($missing.Count -gt 0) {
    Write-Host ("Not found in {0} (check spelling or PAT project access): {1}" -f $script:Org, ($missing -join ', ')) -ForegroundColor Yellow
  }
  if ($targets.Count -eq 0) { throw "No matching projects to assess." }

  $targets = @($targets | Sort-Object { $_.name.ToLowerInvariant() })

  $started = Get-Date
  Write-Host ("Started {0}. Assessing {1} project(s) in {2} (read-only)..." -f $started.ToString('HH:mm:ss'), $targets.Count, $script:Org) -ForegroundColor Cyan
  [void](Get-AdoProcessMap)
  [void](Get-AdoEntitlementMap)

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($ref in $targets) {
    Write-Host ("  {0}" -f $ref.name) -ForegroundColor Cyan
    $project = [pscustomobject]@{
      Name       = [string]$ref.name
      Id         = [string]$ref.id
      Core       = $null
      Security   = $null
      WorkItems  = $null
      Repos      = $null
      Pipelines  = $null
      Releases   = $null
      Feeds      = $null
      Extras     = $null
      LastActivity = $null
      Errors     = New-Object System.Collections.Generic.List[string]
    }

    $project.Core      = Invoke-Collector -Name 'Project details' -Scope 'Project and Team (Read)' -Project $project -Script { Get-ProjectCore $ref }
    $project.Security  = Invoke-Collector -Name 'Teams and security groups' -Scope 'Graph (Read) + Project and Team (Read)' -Project $project -Script { Get-ProjectSecurity $ref $project }
    $project.WorkItems = Invoke-Collector -Name 'Work item types' -Scope 'Work Items (Read)' -Project $project -Script { Get-ProjectWorkItems $ref $project }
    $project.Repos     = Invoke-Collector -Name 'Repos' -Scope 'Code (Read)' -Project $project -Script { Get-ProjectRepos $ref $project }
    $project.Pipelines = Invoke-Collector -Name 'Pipelines' -Scope 'Build (Read)' -Project $project -Script { Get-ProjectPipelines $ref $project }
    $project.Releases  = Invoke-Collector -Name 'Release pipelines' -Scope 'Release (Read)' -Project $project -Script { Get-ProjectReleases $ref $project }
    $project.Feeds     = Invoke-Collector -Name 'Artifact feeds' -Scope 'Packaging (Read)' -Project $project -Script { Get-ProjectFeeds $ref $project }
    $project.Extras    = Get-ProjectExtras $ref $project

    $dates = @()
    if ($project.WorkItems -and $project.WorkItems.LastChanged) { $dates += [datetime]$project.WorkItems.LastChanged }
    if ($project.Repos -and $project.Repos.LastCommit) { $dates += [datetime]$project.Repos.LastCommit }
    if ($project.Pipelines -and $project.Pipelines.LastRun) { $dates += [datetime]$project.Pipelines.LastRun }
    if ($dates.Count -gt 0) { $project.LastActivity = ($dates | Sort-Object -Descending)[0] }

    $results.Add($project)
  }

  # Write outputs
  if (-not $OutputPath) {
    $folder = $script:ReportFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Join-Path (Split-Path $PSScriptRoot -Parent) "reports" }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    $OutputPath = Join-Path $folder ("ADO-Assessment-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
  }
  $jsonPath = [IO.Path]::ChangeExtension($OutputPath, '.json')
  $markdown = New-AssessmentReport -Results $results -Missing $missing -Started $started
  [IO.File]::WriteAllText($OutputPath, $markdown, [Text.UTF8Encoding]::new($false))
  $results | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8

  Write-Host ""
  Write-Host "Report:  $OutputPath" -ForegroundColor Green
  Write-Host "Data:    $jsonPath" -ForegroundColor Green
  $errorCount = ($results | ForEach-Object { $_.Errors.Count } | Measure-Object -Sum).Sum
  if ($errorCount -gt 0) {
    Write-Host "$errorCount collector warning(s) were recorded; see the Warnings section of the report." -ForegroundColor Yellow
  }
  $finished = Get-Date
  $elapsed = $finished - $started
  Write-Host ("Started {0}, finished {1}, elapsed {2:mm\:ss} for {3} project(s)." -f $started.ToString('HH:mm:ss'), $finished.ToString('HH:mm:ss'), $elapsed, $results.Count) -ForegroundColor Cyan
  return $results.ToArray()
}

# =============================================================================
# Report rendering
# =============================================================================

function Coalesce {
  foreach ($a in $args) { if ($null -ne $a -and [string]$a -ne '') { return $a } }
  return $null
}

function MdCell([object]$Value) {
  # Escape text for a Markdown table cell
  if ($null -eq $Value) { return '' }
  $s = [string]$Value
  $s = $s -replace '\|', '\|'
  $s = $s -replace '[\r\n]+', ' '
  return $s.Trim()
}

function Fmt-Date($Value) {
  if ($null -eq $Value -or [string]$Value -eq '') { return '' }
  try { return ([datetime]$Value).ToString('yyyy-MM-dd') } catch { return [string]$Value }
}

function Fmt-Num($Value) {
  if ($null -eq $Value) { return 'n/a' }
  return [string]$Value
}

function Fmt-Age($Value) {
  if ($null -eq $Value -or [string]$Value -eq '') { return '' }
  try {
    $d = [datetime]$Value
    $days = [int]((Get-Date) - $d).TotalDays
    if ($days -lt 1) { return 'today' }
    if ($days -lt 30) { return "$days d ago" }
    if ($days -lt 365) { return "$([int]($days / 30)) mo ago" }
    return "$([math]::Round($days / 365, 1)) yr ago"
  } catch { return '' }
}

function Join-Names([object[]]$Items, [int]$Max = 0) {
  $names = @($Items | Where-Object { $_ } | ForEach-Object { MdCell $_ })
  if ($names.Count -eq 0) { return '' }
  if ($Max -gt 0 -and $names.Count -gt $Max) {
    return (($names | Select-Object -First $Max) -join ', ') + " (+$($names.Count - $Max) more)"
  }
  return ($names -join ', ')
}

function New-AssessmentReport {
  param($Results, $Missing, [datetime]$Started)

  $sb = New-Object System.Text.StringBuilder
  $add = { param($line) [void]$sb.AppendLine($line) }

  & $add "# Azure DevOps Project Assessment"
  & $add ""
  & $add "**Organization:** https://dev.azure.com/$($script:Org)  "
  & $add "**Generated:** $((Get-Date).ToString('yyyy-MM-dd HH:mm')) (local)  "
  & $add "**Projects assessed:** $($Results.Count)  "
  & $add "**Mode:** read-only (GET only)"
  & $add ""
  if ($Missing -and $Missing.Count -gt 0) {
    & $add ("> Not found or not visible to this PAT: " + (($Missing | ForEach-Object { MdCell $_ }) -join ', '))
    & $add ""
  }

  # ---------------------------------------------------------------- Summary
  & $add "## Summary"
  & $add ""
  & $add "| Project | Process | Teams | People | Admins | Contributors | Readers | WI Types | Work Items | Repos | Pipelines | Releases | Feeds | Last Activity |"
  & $add "|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|"
  foreach ($p in $Results) {
    $sec = $p.Security
    $proc = ''
    if ($p.Core) {
      $proc = $p.Core.Process
      if ($p.Core.ProcessParent) { $proc += " ($($p.Core.ProcessParent))" }
    }
    $line = "| $(MdCell $p.Name) | $(MdCell $proc) | " +
      "$(if ($sec) { $sec.Counts.Teams } else { 'n/a' }) | " +
      "$(if ($sec) { $sec.Counts.People } else { 'n/a' }) | " +
      "$(if ($sec) { $sec.Counts.ProjectAdmins } else { 'n/a' }) | " +
      "$(if ($sec) { $sec.Counts.Contributors } else { 'n/a' }) | " +
      "$(if ($sec) { $sec.Counts.Readers } else { 'n/a' }) | " +
      "$(if ($p.WorkItems) { $p.WorkItems.TypeCount } else { 'n/a' }) | " +
      "$(if ($p.WorkItems) { Fmt-Num $p.WorkItems.Total } else { 'n/a' }) | " +
      "$(if ($p.Repos) { $p.Repos.Count } else { 'n/a' }) | " +
      "$(if ($p.Pipelines) { $p.Pipelines.Count } else { 'n/a' }) | " +
      "$(if ($p.Releases) { $p.Releases.Count } else { 'n/a' }) | " +
      "$(if ($p.Feeds) { $p.Feeds.Count } else { 'n/a' }) | " +
      "$(Fmt-Date $p.LastActivity) $(if ($p.LastActivity) { '(' + (Fmt-Age $p.LastActivity) + ')' }) |"
    & $add $line
  }
  & $add ""
  & $add "People counts are distinct users, service principals, and service accounts after expanding nested groups. Contributors and Readers are the members of the project's built-in groups of those names. n/a means the PAT could not read that area; see Warnings."
  & $add ""

  # ---------------------------------------------------------------- Per project
  foreach ($p in $Results) {
    $sec = $p.Security
    & $add "---"
    & $add ""
    & $add "## $(MdCell $p.Name)"
    & $add ""
    if ($p.Core) {
      $desc = $p.Core.Description
      if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "_No description._" }
      & $add $desc.Trim()
      & $add ""
      $procLine = $p.Core.Process
      if ($p.Core.ProcessParent) { $procLine += " (inherited from $($p.Core.ProcessParent))" }
      & $add "| | |"
      & $add "|:--|:--|"
      & $add "| Process | $(MdCell $procLine) |"
      & $add "| Source control | $(MdCell $p.Core.SourceControl)$(if ($p.Repos -and $p.Repos.HasTfvc -and $p.Core.SourceControl -ne 'Tfvc') { ' (TFVC content also present)' }) |"
      & $add "| Visibility | $(MdCell $p.Core.Visibility) |"
      & $add "| State | $(MdCell $p.Core.State) |"
      & $add "| Last activity | $(Fmt-Date $p.LastActivity) $(if ($p.LastActivity) { '(' + (Fmt-Age $p.LastActivity) + ')' }) |"
      & $add "| URL | $($p.Core.Url) |"
      & $add ""
    }

    # At a glance
    & $add "### At a glance"
    & $add ""
    & $add "| Area | Count | Notes |"
    & $add "|:--|--:|:--|"
    if ($sec) {
      & $add "| Teams | $($sec.Counts.Teams) | $(Join-Names ($sec.Teams | ForEach-Object { $_.Name }) 12) |"
      & $add "| People | $($sec.Counts.People) | $($sec.Counts.ProjectAdmins) project admins, $($sec.Counts.Contributors) contributors, $($sec.Counts.Readers) readers |"
    } else {
      & $add "| Teams / People | n/a | Graph or Project scope missing |"
    }
    if ($p.WorkItems) {
      $wiNote = "$(Fmt-Num $p.WorkItems.Total) work items"
      if ($p.WorkItems.LastChanged) { $wiNote += ", last change $(Fmt-Date $p.WorkItems.LastChanged)" }
      if ($null -ne $p.WorkItems.AreaPaths) { $wiNote += "; $($p.WorkItems.AreaPaths) area paths, $($p.WorkItems.IterationPaths) iteration paths" }
      & $add "| Work item types | $($p.WorkItems.TypeCount) | $wiNote |"
    } else { & $add "| Work item types | n/a | |" }
    if ($p.Repos) {
      $rNote = "$($p.Repos.TotalSizeMB) MB total"
      if ($p.Repos.Empty -gt 0) { $rNote += ", $($p.Repos.Empty) empty" }
      if ($p.Repos.Disabled -gt 0) { $rNote += ", $($p.Repos.Disabled) disabled" }
      if ($p.Repos.LastCommit) { $rNote += ", last commit $(Fmt-Date $p.Repos.LastCommit)" }
      & $add "| Git repos | $($p.Repos.Count) | $rNote |"
    } else { & $add "| Git repos | n/a | |" }
    if ($p.Pipelines) {
      $pNote = "$($p.Pipelines.Yaml) YAML, $($p.Pipelines.Classic) classic"
      if ($p.Pipelines.Disabled -gt 0) { $pNote += ", $($p.Pipelines.Disabled) paused/disabled" }
      if ($p.Pipelines.LastRun) { $pNote += ", last run $(Fmt-Date $p.Pipelines.LastRun)" }
      & $add "| Build pipelines | $($p.Pipelines.Count) | $pNote |"
    } else { & $add "| Build pipelines | n/a | |" }
    if ($p.Releases) { & $add "| Release pipelines (classic) | $($p.Releases.Count) | $(Join-Names ($p.Releases.Definitions | ForEach-Object { $_.Name }) 8) |" }
    else { & $add "| Release pipelines (classic) | n/a | |" }
    if ($p.Feeds) { & $add "| Artifact feeds | $($p.Feeds.Count) | $(if ($p.Feeds.Count -gt 0) { "$(Fmt-Num $p.Feeds.Packages) packages" }) |" }
    else { & $add "| Artifact feeds | n/a | |" }
    if ($p.Extras) {
      $x = $p.Extras
      if ($null -ne $x.Wikis) { & $add "| Wikis | $(@($x.Wikis).Count) | $(Join-Names ($x.Wikis | ForEach-Object { "$($_.Name) ($($_.Type))" }) 6) |" }
      if ($null -ne $x.TestPlans) { & $add "| Test plans | $(@($x.TestPlans).Count) | $(Join-Names ($x.TestPlans | ForEach-Object { $_.name }) 6) |" }
      if ($null -ne $x.ServiceConnections) { & $add "| Service connections | $(@($x.ServiceConnections).Count) | $(Join-Names ($x.ServiceConnections | ForEach-Object { $_.Type } | Sort-Object -Unique) 8) |" }
      if ($null -ne $x.AgentQueues) { & $add "| Agent pools available | $(@($x.AgentQueues).Count) | $(Join-Names ($x.AgentQueues | ForEach-Object { $_.Name }) 8) |" }
    }
    & $add ""

    # Teams
    if ($sec) {
      & $add "### Teams ($($sec.Counts.Teams))"
      & $add ""
      & $add "| Team | People | Contributors | Readers | Project Admins | Team Admins | Members |"
      & $add "|:--|--:|--:|--:|--:|:--|:--|"
      foreach ($t in $sec.Teams) {
        $name = MdCell $t.Name
        if ($t.IsDefault) { $name += " (default)" }
        $memberText = Join-Names ($t.Members | ForEach-Object { $_.DisplayName })
        if ($t.NestedGroups.Count -gt 0) { $memberText += " [via groups: $(Join-Names $t.NestedGroups)]" }
        if ($t.Unexpanded.Count -gt 0) { $memberText += " [not expanded: $(Join-Names $t.Unexpanded)]" }
        & $add "| $name | $($t.People) | $($t.Contributors) | $($t.Readers) | $($t.ProjectAdmins) | $(Join-Names $t.TeamAdmins) | $memberText |"
      }
      & $add ""

      # Security groups
      & $add "### Security groups ($($sec.Groups.Count))"
      & $add ""
      & $add "| Group | People | Nested groups | Not expanded |"
      & $add "|:--|--:|--:|:--|"
      foreach ($g in $sec.Groups) {
        & $add "| $(MdCell $g.Name) | $($g.People) | $($g.NestedGroups) | $(Join-Names $g.Unexpanded) |"
      }
      & $add ""

      # People
      $hasAccess = @($sec.People | Where-Object { $_.AccessLevel }).Count -gt 0
      & $add "### People ($($sec.Counts.People))"
      & $add ""
      & $add "| Name | Email | Kind | Roles | Teams | Other groups |$(if ($hasAccess) { ' Access level | Last access |' })"
      & $add "|:--|:--|:--|:--|:--|:--|$(if ($hasAccess) { ':--|:--|' })"
      foreach ($u in $sec.People) {
        $roles = Join-Names $u.Roles
        if (-not $roles) { $roles = "(none of Admin/Contributor/Reader)" }
        $line = "| $(MdCell $u.DisplayName) | $(MdCell $u.Email) | $(MdCell $u.Kind) | $roles | $(Join-Names $u.Teams) | $(Join-Names $u.OtherGroups) |"
        if ($hasAccess) { $line += " $(MdCell $u.AccessLevel) | $(Fmt-Date $u.LastAccessed) |" }
        & $add $line
      }
      & $add ""
    }

    # Work item types
    if ($p.WorkItems) {
      & $add "### Work item types ($($p.WorkItems.TypeCount))"
      & $add ""
      $hasCounts = $null -ne $p.WorkItems.Total
      & $add "| Type | $(if ($hasCounts) { 'Count | ' })Reference name |"
      & $add "|:--|$(if ($hasCounts) { '--:|' }):--|"
      foreach ($t in $p.WorkItems.Types) {
        $tname = MdCell $t.Name
        if ($t.IsDisabled) { $tname += " (disabled)" }
        & $add "| $tname | $(if ($hasCounts) { "$(Fmt-Num $t.Count) | " })$(MdCell $t.Reference) |"
      }
      & $add ""
    }

    # Repos
    if ($p.Repos -and $p.Repos.Count -gt 0) {
      & $add "### Git repositories ($($p.Repos.Count))"
      & $add ""
      & $add "| Repo | Default branch | Branches | Size (MB) | Last commit | By | Notes |"
      & $add "|:--|:--|--:|--:|:--|:--|:--|"
      foreach ($r in $p.Repos.Repos) {
        $notes = @()
        if ($r.IsDisabled) { $notes += 'disabled' }
        if ($r.IsEmpty) { $notes += 'empty' }
        & $add "| $(MdCell $r.Name) | $(MdCell $r.DefaultBranch) | $(Fmt-Num $r.Branches) | $(Fmt-Num $r.SizeMB) | $(Fmt-Date $r.LastCommit) $(if ($r.LastCommit) { '(' + (Fmt-Age $r.LastCommit) + ')' }) | $(MdCell $r.LastAuthor) | $($notes -join ', ') |"
      }
      & $add ""
    }

    # Pipelines
    if ($p.Pipelines -and $p.Pipelines.Count -gt 0) {
      & $add "### Build pipelines ($($p.Pipelines.Count))"
      & $add ""
      & $add "| Pipeline | Folder | Kind | Status | Repo | Last run | Result |"
      & $add "|:--|:--|:--|:--|:--|:--|:--|"
      foreach ($b in $p.Pipelines.Pipelines) {
        & $add "| $(MdCell $b.Name) | $(MdCell $b.Path) | $($b.Kind) | $(MdCell $b.Status) | $(MdCell $b.Repo) | $(Fmt-Date $b.LastRun) $(if ($b.LastRun) { '(' + (Fmt-Age $b.LastRun) + ')' }) | $(MdCell $b.LastResult) |"
      }
      & $add ""
    }
    if ($p.Releases -and $p.Releases.Count -gt 0) {
      & $add "### Release pipelines ($($p.Releases.Count))"
      & $add ""
      & $add "| Release | Folder | Last modified |"
      & $add "|:--|:--|:--|"
      foreach ($r in $p.Releases.Definitions) {
        & $add "| $(MdCell $r.Name) | $(MdCell $r.Path) | $(Fmt-Date $r.LastModified) |"
      }
      & $add ""
    }

    # Feeds
    if ($p.Feeds -and $p.Feeds.Count -gt 0) {
      & $add "### Artifact feeds ($($p.Feeds.Count))"
      & $add ""
      & $add "| Feed | Packages | Protocols | Upstream sources |"
      & $add "|:--|--:|:--|:--|"
      foreach ($f in $p.Feeds.Feeds) {
        & $add "| $(MdCell $f.Name) | $(Fmt-Num $f.Packages) | $(Join-Names $f.Protocols) | $(if ($f.UpstreamEnabled) { 'enabled' } else { 'off' }) |"
      }
      & $add ""
    }

    # Service connections detail
    if ($p.Extras -and $p.Extras.ServiceConnections -and @($p.Extras.ServiceConnections).Count -gt 0) {
      & $add "### Service connections ($(@($p.Extras.ServiceConnections).Count))"
      & $add ""
      & $add "| Name | Type | Shared |"
      & $add "|:--|:--|:--|"
      foreach ($e in ($p.Extras.ServiceConnections | Sort-Object Name)) {
        & $add "| $(MdCell $e.Name) | $(MdCell $e.Type) | $(if ($e.IsShared) { 'yes' } else { '' }) |"
      }
      & $add ""
    }

    # Warnings
    if ($p.Errors.Count -gt 0) {
      & $add "### Warnings"
      & $add ""
      foreach ($e in $p.Errors) { & $add "- $(MdCell $e)" }
      & $add ""
    }
  }

  # ---------------------------------------------------------------- Work item type matrix
  $withTypes = @($Results | Where-Object { $_.WorkItems })
  if ($withTypes.Count -gt 0) {
    & $add "---"
    & $add ""
    & $add "## Work item types across projects"
    & $add ""
    & $add "Count of work items per type in each project. A dash means the type does not exist in that project's process. n/a means the count could not be read (Analytics scope)."
    & $add ""
    $typeNames = @($withTypes | ForEach-Object { $_.WorkItems.Types } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $header = "| Work item type |"
    $sep = "|:--|"
    foreach ($p in $withTypes) { $header += " $(MdCell $p.Name) |"; $sep += "--:|" }
    $header += " Total |"; $sep += "--:|"
    & $add $header
    & $add $sep
    $colTotals = @{}
    foreach ($tn in $typeNames) {
      $line = "| $(MdCell $tn) |"
      $rowTotal = 0
      foreach ($p in $withTypes) {
        $t = $p.WorkItems.Types | Where-Object { $_.Name -eq $tn } | Select-Object -First 1
        if (-not $t) { $line += " - |"; continue }
        if ($null -eq $t.Count) { $line += " n/a |"; continue }
        $line += " $($t.Count) |"
        $rowTotal += [int]$t.Count
        if (-not $colTotals.ContainsKey($p.Name)) { $colTotals[$p.Name] = 0 }
        $colTotals[$p.Name] += [int]$t.Count
      }
      $line += " $rowTotal |"
      & $add $line
    }
    $totalLine = "| **Total** |"
    $grand = 0
    foreach ($p in $withTypes) {
      if ($colTotals.ContainsKey($p.Name)) { $totalLine += " **$($colTotals[$p.Name])** |"; $grand += $colTotals[$p.Name] }
      else { $totalLine += " n/a |" }
    }
    $totalLine += " **$grand** |"
    & $add $totalLine
    & $add ""
  }

  $elapsed = (Get-Date) - $Started
  & $add "---"
  & $add ""
  & $add "_Started $($Started.ToString('yyyy-MM-dd HH:mm:ss')), collected in $([int]$elapsed.TotalSeconds) seconds using read-only REST calls. Generated by AssessProjects.ps1._"
  return $sb.ToString()
}

# The tests set this to load the functions without running Main. It has to be explicit: VS Code's
# F5 dot-sources the file too, so the script cannot tell a test run from how it was invoked.
if ($global:AssessProjectsLoadFunctionsOnly) {
  Write-Host "Functions loaded, Main skipped." -ForegroundColor DarkGray
} else {
  Main
}

