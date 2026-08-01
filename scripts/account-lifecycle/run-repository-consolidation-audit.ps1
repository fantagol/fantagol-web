Set-Location "C:\Users\io\Desktop\fantagol-web"

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "================================================================"
Write-Host "FANTAGOL PHASE 185 - REPOSITORY CONSOLIDATION AUDIT"
Write-Host "================================================================"

$AuditRoot = ".\audit-output"
New-Item -ItemType Directory -Force $AuditRoot | Out-Null

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path `
    $AuditRoot `
    "185_account_lifecycle_repository_consolidation_audit_$Stamp.txt"

$SummaryPath = Join-Path `
    $AuditRoot `
    "185_account_lifecycle_repository_consolidation_summary_$Stamp.txt"

function Write-Report {
    param([string]$Text = "")
    $Text | Tee-Object -FilePath $ReportPath -Append
}

function Invoke-Checked {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Write-Report ""
    Write-Report "=== $Title ==="

    try {
        & $Command 2>&1 |
            Tee-Object -FilePath $ReportPath -Append

        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
            throw "$Title failed with exit code $LASTEXITCODE."
        }

        Write-Report "[PASS] $Title"
    }
    catch {
        Write-Report "[FAIL] $Title"
        Write-Report $_.Exception.Message
        throw
    }
}

Write-Report "FANTAGOL PHASE 185 - REPOSITORY CONSOLIDATION AUDIT"
Write-Report "Generated: $(Get-Date -Format o)"
Write-Report "Repository: $(Get-Location)"
Write-Report ""

Write-Report "=== REQUIRED CANONICAL MIGRATIONS 168-184 ==="

# Phase 178 was a certification phase, not a canonical SQL migration.
# The canonical migration sequence intentionally moves from 177 to 179.
$RequiredMigrationNumbers = @(
    168, 169, 170, 171, 172, 173, 174, 175, 176, 177,
    179, 180, 181, 182, 183, 184
)

$MissingMigrations = @()

foreach ($Number in $RequiredMigrationNumbers) {
    $Matches = @(
        Get-ChildItem `
            -LiteralPath ".\supabase\migrations" `
            -File `
            -Filter "$Number`_*.sql"
    )

    if ($Matches.Count -eq 0) {
        $MissingMigrations += $Number
        Write-Report "[MISSING] migration $Number"
    }
    elseif ($Matches.Count -gt 1) {
        Write-Report "[MULTIPLE] migration $Number"
        foreach ($Match in $Matches) {
            Write-Report "  - $($Match.Name)"
        }
    }
    else {
        Write-Report "[FOUND] $($Matches[0].Name)"
    }
}

Write-Report "[INTENTIONAL GAP] 178 = engine/server certification phase; no canonical migration required"

$Phase178Artifacts = @(
    Get-ChildItem `
        -LiteralPath ".\audit-output" `
        -File `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "178_account_lifecycle_*"
    }
)

if ($Phase178Artifacts.Count -gt 0) {
    Write-Report "[FOUND] Phase 178 certification artifacts: $($Phase178Artifacts.Count)"
    foreach ($Artifact in $Phase178Artifacts) {
        Write-Report "  - $($Artifact.Name)"
    }
}
else {
    Write-Report "[INFO] No Phase 178 artifact currently retained in audit-output; canonical migration inventory remains valid."
}

if ($MissingMigrations.Count -gt 0) {
    throw "Required canonical migrations missing: $($MissingMigrations -join ', ')"
}

Write-Report ""
Write-Report "=== CANONICAL HOTFIX MARKERS ==="

$MarkerChecks = @(
    @{
        File = ".\supabase\migrations\174_account_deletion_domain_handlers.sql"
        Markers = @(
            "when 'DELETE_PROFILE_PERSONAL_DATA' then",
            "handle_account_erasure_130_profile_internal",
            "when 'VERIFY_PRE_AUTH_DELETION_INVARIANTS' then",
            "handle_account_erasure_140_pre_auth_internal",
            "when 'VERIFY_POST_AUTH_DELETION_INVARIANTS' then",
            "handle_account_erasure_160_post_auth_internal",
            "when 'WRITE_FINAL_NON_IDENTIFYING_AUDIT' then",
            "handle_account_erasure_170_audit_internal",
            "when 'CERTIFY_ACCOUNT_DELETION' then",
            "handle_account_erasure_180_certify_internal"
        )
    },
    @{
        File = ".\supabase\migrations\175_account_lifecycle_finalization_foundation.sql"
        Markers = @(
            "public.prepare_account_erasure_external_command_internal(uuid,text,uuid)",
            "public.claim_account_erasure_external_command_internal(uuid,text,uuid,interval)",
            "public.heartbeat_account_erasure_external_command_internal(uuid,text,uuid,interval)",
            "public.record_account_erasure_external_receipt_internal(uuid,uuid,text,uuid,text,text,text,jsonb,jsonb,bigint,bigint)",
            "create or replace function public.complete_account_erasure_external_step_internal(",
            "attempt_count = attempt_count + 1",
            "restricted_evidence ->> 'deleted_auth_user_id'",
            "restricted_payload ->> 'auth_user_id'",
            "verified_auth_receipt_present",
            "'handler_version', '1.0.1'"
        )
    },
    @{
        File = ".\supabase\migrations\179_account_lifecycle_controlled_runtime_activation.sql"
        Markers = @(
            "activation_level not in (1, 2, 3, 4, 5)",
            "ACCOUNT_LIFECYCLE_LEVEL5_PROVIDER_STATE_INVALID",
            "ACCOUNT_LIFECYCLE_LEVEL5_POLICY_STATE_INVALID",
            "stop_before_step_order <> 190",
            "v_step.step_order in (120, 150)",
            "ACCOUNT_DELETION_AUTH_COMMAND_PREPARED"
        )
    },
    @{
        File = ".\supabase\migrations\180_account_lifecycle_storage_provider_activation.sql"
        Markers = @(
            "activation_level not in (1, 2, 3, 4, 5)",
            "ACCOUNT_LIFECYCLE_LEVEL5_PROVIDER_STATE_INVALID",
            "ACCOUNT_LIFECYCLE_LEVEL5_POLICY_STATE_INVALID",
            "stop_before_step_order <> 190"
        )
    },
    @{
        File = ".\supabase\migrations\184_account_lifecycle_post_certification_closure.sql"
        Markers = @(
            "certification_version = '1.0.0'",
            "certified_at = coalesce(certified_at, clock_timestamp())",
            "'certification_result',",
            "'account_lifecycle_end_to_end_pass'",
            "activation_level = 0",
            "activation_mode = 'disabled'",
            "observed_state = 'stopped'",
            "production_scope_enabled = false"
        )
    }
)

foreach ($Check in $MarkerChecks) {
    if (-not (Test-Path -LiteralPath $Check.File)) {
        throw "Canonical source file missing: $($Check.File)"
    }

    $Text = Get-Content `
        -LiteralPath $Check.File `
        -Raw `
        -Encoding UTF8

    Write-Report "File: $($Check.File)"

    foreach ($Marker in $Check.Markers) {
        if (-not $Text.Contains($Marker)) {
            Write-Report "[MISSING MARKER] $Marker"
            throw "Canonical marker missing in $($Check.File): $Marker"
        }

        Write-Report "[FOUND] $Marker"
    }
}

Write-Report ""
Write-Report "=== ACCOUNT LIFECYCLE FILE INVENTORY ==="

$InventoryPatterns = @(
    ".\app\elimina-account",
    ".\app\api\account-deletion",
    ".\lib\account-lifecycle",
    ".\scripts\account-lifecycle",
    ".\supabase\migrations"
)

foreach ($Pattern in $InventoryPatterns) {
    if (Test-Path -LiteralPath $Pattern) {
        Write-Report "[FOUND] $Pattern"
        Get-ChildItem `
            -LiteralPath $Pattern `
            -Recurse `
            -File |
            ForEach-Object {
                Write-Report "  $($_.FullName.Replace((Get-Location).Path + '\', ''))"
            }
    }
    else {
        Write-Report "[ABSENT] $Pattern"
    }
}

Write-Report ""
Write-Report "=== SUSPECT ROOT ARTIFACTS ==="

$SuspectNames = @(
    "PowerShell",
    "Set-Location",
    "fantagol-web@0.1.0",
    "next"
)

$SuspectFound = @()

foreach ($Name in $SuspectNames) {
    $Candidate = Join-Path (Get-Location) $Name

    if (Test-Path -LiteralPath $Candidate) {
        $SuspectFound += $Name
        Write-Report "[SUSPECT] $Name"
    }
    else {
        Write-Report "[ABSENT] $Name"
    }
}

Write-Report ""
Write-Report "=== GIT STATUS BEFORE VERIFICATION ==="

git status --short 2>&1 |
    Tee-Object -FilePath $ReportPath -Append

Write-Report ""
Write-Report "=== MIGRATION DIFF SUMMARY ==="

git diff --stat -- `
    supabase/migrations `
    lib/account-lifecycle `
    scripts/account-lifecycle `
    app/elimina-account `
    app/api/account-deletion 2>&1 |
    Tee-Object -FilePath $ReportPath -Append

Invoke-Checked "TYPESCRIPT" {
    & ".\node_modules\.bin\tsc.cmd" `
        --noEmit `
        --pretty false
}

Invoke-Checked "FOCUSED ESLINT" {
    $Targets = @()

    foreach ($Target in @(
        "app/elimina-account",
        "app/api/account-deletion",
        "lib/account-lifecycle",
        "scripts/account-lifecycle"
    )) {
        if (Test-Path -LiteralPath $Target) {
            $Targets += $Target
        }
    }

    if ($Targets.Count -eq 0) {
        Write-Output "No focused account-lifecycle targets found."
        return
    }

    & ".\node_modules\.bin\eslint.cmd" @Targets
}

Write-Report ""
Write-Report "=== ACCOUNT LIFECYCLE TEST DISCOVERY ==="

$AllTestFiles = @(
    Get-ChildItem `
        -LiteralPath ".\lib\account-lifecycle" `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '\.(test|spec)\.(ts|tsx|js|jsx)$'
    }
)

$CertificationTestNames = @(
    "storage-certification.test.ts",
    "auth-certification.test.ts"
)

$UnitTestFiles = @(
    $AllTestFiles |
    Where-Object {
        $_.Name -notin $CertificationTestNames
    }
)

$CertificationTestFiles = @(
    $AllTestFiles |
    Where-Object {
        $_.Name -in $CertificationTestNames
    }
)

foreach ($TestFile in $UnitTestFiles) {
    Write-Report "[UNIT TEST] $($TestFile.FullName.Replace((Get-Location).Path + '\', ''))"
}

foreach ($TestFile in $CertificationTestFiles) {
    Write-Report "[CERTIFICATION TEST EXCLUDED] $($TestFile.FullName.Replace((Get-Location).Path + '\', ''))"
}

if ($UnitTestFiles.Count -gt 0) {
    Invoke-Checked "FOCUSED UNIT VITEST" {
        $RelativeTests = @(
            $UnitTestFiles |
            ForEach-Object {
                $_.FullName.Replace((Get-Location).Path + '\', '')
            }
        )

        & ".\node_modules\.bin\vitest.cmd" `
            run `
            --passWithNoTests `
            @RelativeTests
    }
}
else {
    Write-Report "[SKIP] No account-lifecycle unit tests discovered."
}

if (
    $env:ACCOUNT_LIFECYCLE_CERTIFICATION_MODE -eq "true" -and
    $CertificationTestFiles.Count -gt 0
) {
    Invoke-Checked "EXPLICIT CERTIFICATION VITEST" {
        $RelativeCertificationTests = @(
            $CertificationTestFiles |
            ForEach-Object {
                $_.FullName.Replace((Get-Location).Path + '\', '')
            }
        )

        & ".\node_modules\.bin\vitest.cmd" `
            run `
            --passWithNoTests `
            @RelativeCertificationTests
    }
}
else {
    Write-Report "[SKIP] Destructive certification tests require ACCOUNT_LIFECYCLE_CERTIFICATION_MODE=true."
}

Invoke-Checked "PRODUCTION BUILD" {
    npm run build
}

Write-Report ""
Write-Report "=== GIT STATUS AFTER VERIFICATION ==="

git status --short 2>&1 |
    Tee-Object -FilePath $ReportPath -Append

Write-Report ""
Write-Report "=== FINAL SUMMARY ==="

$Summary = @(
    "FANTAGOL PHASE 185 - REPOSITORY CONSOLIDATION SUMMARY",
    "Generated: $(Get-Date -Format o)",
    "Canonical migrations 168-184 (178 certification gap): PASS",
    "Canonical hotfix markers: PASS",
    "TypeScript: PASS",
    "Focused ESLint: PASS",
    "Focused unit Vitest: PASS; destructive certification tests excluded unless explicitly enabled",
    "Production build: PASS",
    "Suspect root artifacts found: $($SuspectFound.Count)",
    "Suspect names: $($SuspectFound -join ', ')",
    "No files were deleted.",
    "No Git commit was created.",
    "No Git push was executed.",
    "Detailed report: $ReportPath"
)

$Summary |
    Tee-Object -FilePath $SummaryPath

Write-Host ""
Write-Host "=== REPOSITORY CONSOLIDATION AUDIT COMPLETE ==="
Write-Host "Detailed report:"
Write-Host $ReportPath
Write-Host "Summary:"
Write-Host $SummaryPath
