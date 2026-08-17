param(
    [string]$RtlDir = "F:\ic_FPGA\FPGA\project\tv_verification\sc_fast_ssc_small",
    [string]$WorkDir = ""
)

$ErrorActionPreference = "Stop"
$vivadoBin = "E:\verilog\Vivado\2024.2\bin"

if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP ("sc_fast_ssc_regress_" + [guid]::NewGuid().ToString("N"))
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir
$summary = @()

try {
    Write-Host "== xvlog compile RTL =="
    $rtlFiles = @(
        "sc_pe.v",
        "sc_llr_mem.v",
        "sc_beta_mem.v",
        "sc_uhat_mem.v",
        "frozen_gen.v",
        "polar_reliability_rom.v",
        "sc_fast_node_rom.v",
        "sc_datapath.v",
        "controller.v",
        "sc_decoder_core.v"
    ) | ForEach-Object { Join-Path $RtlDir $_ }

    & (Join-Path $vivadoBin "xvlog.bat") $rtlFiles 2>&1 | Tee-Object -FilePath "xvlog_rtl.log"
    if ($LASTEXITCODE -ne 0) { throw "xvlog RTL failed" }

    $tbList = @(
        @{ File = "tb_llr_vec_bounds.v";       Top = "tb_llr_vec_bounds" },
        @{ File = "sc_datapath_tb.v";          Top = "sc_datapath_tb" },
        @{ File = "tb_fast_zero_fallback_64.v";Top = "tb_fast_zero_fallback_64" },
        @{ File = "tb_256.v";                  Top = "sc_bc_n256_system_tb" },
        @{ File = "tb_1024.v";                 Top = "sc_bc_n1024_system_tb" },
        @{ File = "sc_five_n_switch_tb.v";     Top = "sc_five_n_switch_tb" }
    )

    foreach ($tb in $tbList) {
        $top = $tb.Top
        Write-Host "== $top =="

        & (Join-Path $vivadoBin "xvlog.bat") (Join-Path $RtlDir $tb.File) 2>&1 |
            Tee-Object -FilePath "xvlog_$top.log"
        if ($LASTEXITCODE -ne 0) { throw "xvlog TB failed: $top" }

        & (Join-Path $vivadoBin "xelab.bat") -snapshot $top -top $top -debug off 2>&1 |
            Tee-Object -FilePath "xelab_$top.log"
        if ($LASTEXITCODE -ne 0) { throw "xelab failed: $top" }

        & (Join-Path $vivadoBin "xsim.bat") $top -R 2>&1 |
            Tee-Object -FilePath "xsim_$top.log"

        $result = Select-String -Path "xsim_$top.log" -Pattern "RESULT: .* (PASS|FAIL)" |
            Select-Object -Last 1
        if ($result) {
            $summary += "$top : $($result.Line.Trim())"
        } else {
            $summary += "$top : NO RESULT FOUND"
        }
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "===== REGRESSION SUMMARY ====="
$summary | ForEach-Object { Write-Host $_ }
Write-Host "Work dir: $WorkDir"
