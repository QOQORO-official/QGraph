# Windows equivalent of build.sh: Nim -> C -> LLVM -> WASM, no Binaryen.
param(
    [string]$LlvmBin = $env:QGRAPH_LLVM_BIN,
    [string]$WasmLd = $env:QGRAPH_WASM_LD
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $LlvmBin) {
    $cached = Join-Path $root 'build/.cache/llvm-mingw-20240619-ucrt-x86_64/bin'
    if (Test-Path (Join-Path $cached 'clang.exe')) { $LlvmBin = $cached }
}
$clang = if ($LlvmBin) { Join-Path $LlvmBin 'clang.exe' } else { 'clang' }
$linker = if ($WasmLd) { $WasmLd } elseif ($LlvmBin) { Join-Path $LlvmBin 'wasm-ld.exe' } else { 'wasm-ld' }
$linkerPrefix = @()
if (-not $WasmLd -and $LlvmBin -and -not (Test-Path -LiteralPath $linker)) {
    # LLVM-MinGW emits LLVM bitcode but its LLD excludes the WASM backend.
    # Rust's matching LLVM 18 linker can perform the WASM code generation.
    $rustLinker = Join-Path $env:USERPROFILE '.rustup/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/gcc-ld/wasm-ld.exe'
    if (Test-Path -LiteralPath $rustLinker) { $linker = $rustLinker }
    else { throw 'Set QGRAPH_WASM_LD to a WASM-capable linker matching the compiler LLVM version.' }
}
Get-Command $clang, $linker -ErrorAction Stop | Out-Null
$nim = (Get-Command nim -ErrorAction Stop).Source
$nimLib = Join-Path (Split-Path (Split-Path $nim -Parent) -Parent) 'lib'
# A fresh build folder avoids stale objects without deleting previous builds.
$cache = Join-Path $root ('build/.nimcache/windows-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $cache -Force | Out-Null
& $nim c --cpu:wasm32 --os:any --mm:arc -d:useMalloc --exceptions:goto --panics:on -d:danger --opt:speed --noMain:on --compileOnly:on "--nimcache:$cache" --header:off --hints:off (Join-Path $root 'src/app/main.nim')
if ($LASTEXITCODE -ne 0) { throw 'Nim compilation failed' }
$flags = @('--target=wasm32','-O3','-flto','-nostdlib','-ffreestanding','-mbulk-memory',
    '-fno-builtin-malloc','-fno-builtin-calloc','-fno-builtin-realloc','-fno-builtin-free',
    '-isystem',(Join-Path $root 'build/inc'),"-I$nimLib",'-DNIM_INTBITS=32',
    '-Wno-implicit-function-declaration','-Wno-incompatible-library-redeclaration','-Wno-builtin-requires-header')
$sources = @((Join-Path $root 'build/libc.c')) + @(Get-ChildItem -LiteralPath $cache -Filter '*.nim.c' | ForEach-Object FullName)
$objects = @()
foreach ($source in $sources) {
    $object = Join-Path $cache ((Split-Path $source -Leaf) + '.o')
    & $clang @flags -c $source -o $object
    if ($LASTEXITCODE -ne 0) { throw "Clang failed: $source" }
    $objects += $object
}
$output = Join-Path $cache 'qgraph.wasm'
& $linker @linkerPrefix --no-entry --lto-O3 --allow-undefined --export-dynamic --export=__heap_base --export=memory -z stack-size=1048576 --initial-memory=33554432 --max-memory=2147483648 -o $output @objects
if ($LASTEXITCODE -ne 0) { throw 'WASM linking failed' }
Copy-Item -LiteralPath $output -Destination (Join-Path $root 'web/js/qgraph.wasm') -Force
Write-Host "Built QoChart without Binaryen: $((Get-Item $output).Length) bytes"
