<#
.SYNOPSIS
  Removes test artifacts left by QA runs so the demo shows only meaningful data.
  Deletes ONLY:
    - rules whose name starts with "QA " (created by run-qa.ps1), with their versions, runs and stored violations
    - AI suggestions still waiting for review (status Proposed)
    - with -IncludeAiDrafts: also rules created by accepting AI suggestions that are still Draft
  Business data (biz schema), the catalog and the 7 sample rules are never touched. Runs in one transaction.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\cleanup-demo-data.ps1 [-IncludeAiDrafts] [-Server .\SQLEXPRESS]
#>
param([string]$Server = '.\SQLEXPRESS', [switch]$IncludeAiDrafts)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ruleFilter = "Name LIKE N'QA %'" + $(if ($IncludeAiDrafts) { " OR (Origin = N'AI' AND Status = N'Draft')" } else { '' })
$sql = @"
SET XACT_ABORT ON;
BEGIN TRAN;
DECLARE @r TABLE (Id UNIQUEIDENTIFIER PRIMARY KEY);
INSERT INTO @r SELECT Id FROM dq.[Rule] WHERE $ruleFilter;
DELETE v FROM dq.RuleRunViolation v JOIN dq.RuleRun rr ON rr.Id = v.RunId WHERE rr.RuleId IN (SELECT Id FROM @r);
DELETE FROM dq.RuleRun WHERE RuleId IN (SELECT Id FROM @r);
DELETE FROM dq.RuleVersion WHERE RuleId IN (SELECT Id FROM @r);
UPDATE dq.AiSuggestion SET AcceptedRuleId = NULL WHERE AcceptedRuleId IN (SELECT Id FROM @r);
DELETE FROM dq.[Rule] WHERE Id IN (SELECT Id FROM @r);
DECLARE @rules INT = @@ROWCOUNT;
DELETE FROM dq.AiSuggestion WHERE Status = N'Proposed';
DECLARE @sugg INT = @@ROWCOUNT;
COMMIT;
SELECT @rules AS RulesDeleted, @sugg AS SuggestionsDeleted, (SELECT COUNT(*) FROM dq.[Rule]) AS RulesLeft;
"@
$c = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=DataControls;Integrated Security=True;TrustServerCertificate=True")
$c.Open()
try {
    $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
    $rd = $cmd.ExecuteReader()
    if ($rd.Read()) { Write-Host "Deleted rules: $($rd['RulesDeleted'])  Deleted pending suggestions: $($rd['SuggestionsDeleted'])  Rules left: $($rd['RulesLeft'])" -ForegroundColor Green }
    $rd.Close()
} finally { $c.Close() }
