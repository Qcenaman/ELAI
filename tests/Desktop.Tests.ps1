# Pester 5 tests for the desktop stage. Run: Invoke-Pester -Path tests -CI
BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptFiles = @(Get-ChildItem -Path (Join-Path $script:RepoRoot "desktop") -Filter "*.ps1" | ForEach-Object { $_.FullName })
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Desktop = Join-Path $script:RepoRoot "desktop"
    . (Join-Path $script:Desktop "elai-common.ps1")
    $script:Settings = Get-Content (Join-Path $script:Desktop "elai.json") -Raw | ConvertFrom-Json

    function New-TempDir {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("elai-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        return $p
    }
    function New-DummyModels {
        param([string]$Dir, $Settings)
        foreach ($p in $Settings.models.PSObject.Properties) {
            Set-Content -Path (Join-Path $Dir $p.Value.file) -Value "dummy"
            if (Test-Prop $p.Value 'mmproj') { Set-Content -Path (Join-Path $Dir $p.Value.mmproj) -Value "dummy" }
        }
    }
}

Describe "elai.json" {
    It "has the top-level keys" {
        foreach ($k in @('root', 'modelsDir', 'host', 'port', 'llama', 'router', 'models', 'opencode', 'tokensaver')) {
            $script:Settings.PSObject.Properties.Name | Should -Contain $k
        }
    }
    It "uses a sane TCP port" {
        [int]$script:Settings.port | Should -BeGreaterThan 1023
        [int]$script:Settings.port | Should -BeLessThan 65536
    }
    It "defines coder and planner with a repo, a file and a size" {
        foreach ($n in @('coder', 'planner')) {
            $m = $script:Settings.models.$n
            $m | Should -Not -BeNullOrEmpty
            $m.repo | Should -Match '^[\w.-]+/[\w.-]+$'
            $m.file | Should -Match '\.gguf$'
            [long]$m.sizeBytes | Should -BeGreaterThan 1GB
            [int]$m.slots | Should -BeGreaterThan 0
            ([int]$m.ctx % [int]$m.slots) | Should -Be 0
        }
    }
    It "pins a llama.cpp nightly tag and a CUDA backend first" {
        $script:Settings.llama.tag | Should -Match '^(b\d+|latest)$'
        @($script:Settings.llama.backends)[0] | Should -Match '^cuda'
    }
}

Describe "desktop scripts" {
    It "parses: <_>" -ForEach $script:ScriptFiles {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0 -Because (@($errors | ForEach-Object { $_.Message }) -join "; ")
    }
    It "is plain ASCII (safe for Windows PowerShell 5.1 without a BOM): <_>" -ForEach $script:ScriptFiles {
        $bytes = [System.IO.File]::ReadAllBytes($_)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It "does not use PowerShell 7-only syntax: <_>" -ForEach $script:ScriptFiles {
        $text = Get-Content $_ -Raw
        $text | Should -Not -Match '\?\?'
        $text | Should -Not -Match '-AsHashtable'
        $text | Should -Not -Match '-AdditionalChildPath'
    }
}

Describe "elai-common helpers" {
    It "resolves an explicit models dir as-is" {
        Resolve-ModelsDir -Configured "X:\somewhere" -Root "X:\root" | Should -Be "X:\somewhere"
    }
    It "falls back to <root>\models when no candidate exists" {
        $root = New-TempDir
        Resolve-ModelsDir -Configured "auto" -Root $root -Candidates @((Join-Path $root "nope")) | Should -Be (Join-Path $root "models")
    }
    It "prefers the first existing candidate" {
        $root = New-TempDir
        $c1 = Join-Path $root "c1"; $c2 = Join-Path $root "c2"
        New-Item -ItemType Directory -Path $c2 | Out-Null
        Resolve-ModelsDir -Configured "auto" -Root $root -Candidates @($c1, $c2) | Should -Be $c2
    }
    It "finds llama-server.exe or the unified llama.exe" {
        $d = New-TempDir
        Get-LlamaServer -LlamaDir $d | Should -BeNullOrEmpty
        Set-Content (Join-Path $d "llama.exe") "x"
        (Get-LlamaServer -LlamaDir $d).Prefix | Should -Be @("serve")
        Set-Content (Join-Path $d "llama-server.exe") "x"
        (Get-LlamaServer -LlamaDir $d).Exe | Should -Be (Join-Path $d "llama-server.exe")
    }
    It "formats bytes" {
        Format-Bytes 46079830016 | Should -Match 'GB'
    }
}

Describe "make-preset.ps1" {
    BeforeAll {
        $script:Root = New-TempDir
        $script:Models = New-TempDir
        New-DummyModels -Dir $script:Models -Settings $script:Settings
        & (Join-Path $script:Desktop "make-preset.ps1") -Root $script:Root -ModelsDir $script:Models -Quiet
        $script:Ini = Get-Content (Join-Path $script:Root "models.ini") -Raw
        $script:Cmd = Get-Content (Join-Path $script:Root "start-hub.cmd") -Raw
    }
    It "writes the version header and a global section" {
        $script:Ini | Should -Match '(?m)^version = 1'
        $script:Ini | Should -Match '(?m)^\[\*\]'
        $script:Ini | Should -Match '(?m)^cache-type-k = q8_0'
    }
    It "has a section per model that loads on startup" {
        foreach ($n in @('coder', 'planner')) {
            $script:Ini | Should -Match ("(?m)^\[$n\]")
        }
        ([regex]::Matches($script:Ini, '(?m)^load-on-startup = true')).Count | Should -Be 2
    }
    It "points model = at the real files" {
        $script:Ini | Should -Match ('(?m)^model = .*' + [regex]::Escape($script:Settings.models.coder.file))
        $script:Ini | Should -Match ('(?m)^model = .*' + [regex]::Escape($script:Settings.models.planner.file))
    }
    It "keeps the coder's experts in system RAM and the planner on the GPU" {
        $coder = ($script:Ini -split '(?m)^\[planner\]')[0]
        $planner = ($script:Ini -split '(?m)^\[planner\]')[1]
        $coder | Should -Match '(?m)^cpu-moe = true'
        $coder | Should -Match '(?m)^n-gpu-layers = 99'
        $planner | Should -Not -Match '(?m)^cpu-moe'
        $planner | Should -Match '(?m)^reasoning-format = deepseek'
    }
    It "writes context and slots per model" {
        $script:Ini | Should -Match ('(?m)^ctx-size = ' + [int]$script:Settings.models.coder.ctx)
        $script:Ini | Should -Match ('(?m)^parallel = ' + [int]$script:Settings.models.coder.slots)
    }
    It "writes sampling values with a dot decimal separator" {
        $script:Ini | Should -Match '(?m)^top-p = 0\.95'
        $script:Ini | Should -Not -Match ','
    }
    It "writes a launcher that TokenSaver can read the port from" {
        $script:Cmd | Should -Match ('--port ' + [int]$script:Settings.port)
        $script:Cmd | Should -Match '--models-preset'
        $script:Cmd | Should -Match '--host 0\.0\.0\.0'
        $script:Cmd | Should -Match '(?m)^@echo off'
    }
    It "fails when a model file is missing" {
        $empty = New-TempDir
        { & (Join-Path $script:Desktop "make-preset.ps1") -Root (New-TempDir) -ModelsDir $empty -Quiet } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe "opencode.elai.json" {
    BeforeAll {
        $raw = Get-Content (Join-Path $script:Desktop "opencode.elai.json") -Raw
        $raw = $raw.Replace('__HUB_URL__', 'http://127.0.0.1:8080/v1').Replace('__TOKENSAVER_EXE__', 'C:\\x\\tokensaver.exe')
        $script:Oc = $raw | ConvertFrom-Json
    }
    It "is valid JSON with the V2 keys" {
        $script:Oc.providers.elai | Should -Not -BeNullOrEmpty
        $script:Oc.providers.elai.package | Should -Be '@opencode/ai/providers/openai-compatible'
        $script:Oc.model | Should -Be 'elai/coder'
        $script:Oc.mcp.servers.tokensaver.type | Should -Be 'local'
        @($script:Oc.mcp.servers.tokensaver.command)[0] | Should -Be 'C:\x\tokensaver.exe'
    }
    It "defines both hub models with tool support" {
        foreach ($n in @('coder', 'planner')) {
            $script:Oc.providers.elai.models.$n.modelID | Should -Be $n
            $script:Oc.providers.elai.models.$n.capabilities.tools | Should -BeTrue
        }
    }
    It "defines the coder and reviewer agents" {
        $script:Oc.agents.'elai-coder'.mode | Should -Be 'primary'
        $script:Oc.agents.'elai-reviewer'.mode | Should -Be 'subagent'
        $script:Oc.agents.'elai-coder'.system | Should -Match 'branch'
    }
}

Describe "install-opencode.ps1 -ConfigOnly" {
    It "merges the hub into an existing config without losing other keys" {
        $dir = New-TempDir
        $cfg = Join-Path $dir "opencode.json"
        $ts = Join-Path $dir "tokensaver.exe"
        Set-Content $ts "x"
        '{ "theme": "dark", "providers": { "other": { "name": "keep me" } } }' | Set-Content $cfg
        & (Join-Path $script:Desktop "install-opencode.ps1") -ConfigOnly -Root (New-TempDir) -ConfigPath $cfg -TokenSaverExe $ts -HubUrl "http://10.0.0.5:8080/v1" | Out-Null
        $out = Get-Content $cfg -Raw | ConvertFrom-Json
        $out.theme | Should -Be 'dark'
        $out.providers.other.name | Should -Be 'keep me'
        $out.providers.elai.settings.baseURL | Should -Be 'http://10.0.0.5:8080/v1'
        @($out.mcp.servers.tokensaver.command)[0] | Should -Be $ts
        $out.model | Should -Be 'elai/coder'
        [int]$out.providers.elai.models.coder.limit.context | Should -Be ([int]$script:Settings.models.coder.ctx / [int]$script:Settings.models.coder.slots)
        Test-Path ($cfg + ".bak") | Should -BeTrue
    }
}
