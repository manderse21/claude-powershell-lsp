Describe 'File URI round-trip fuzzing' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../scripts/lib/lsp-common.ps1')
    }

    It 'preserves absolute paths across URI encoding and decoding' {
        $seed = Get-Random -Minimum 1 -Maximum 2147483647
        $random = [Random]::new($seed)
        $tokens = @('a', 'Z', '0', ' ', '#', '%', '+', '[', ']', [string][char]0x00e9)
        for ($case = 0; $case -lt 256; $case++) {
            $path = [IO.Path]::GetFullPath($TestDrive)
            $depth = $random.Next(1, 5)
            for ($level = 0; $level -lt $depth; $level++) {
                $length = $random.Next(1, 13)
                $segment = -join $(for ($i = 0; $i -lt $length; $i++) {
                    $tokens[$random.Next($tokens.Count)]
                })
                $path = [IO.Path]::Combine($path, "x${segment}z")
            }
            $encoded = ConvertTo-FileUri -Path $path
            $decoded = ConvertFrom-FileUri -Uri $encoded
            $decoded | Should -BeExactly $path -Because "seed=$seed case=$case URI=$encoded"
        }
    }
}
