param([string]$OutDir = 'C:\claude\modpack', [string]$Version = '1.0.2')
$ErrorActionPreference = 'Stop'
$api = 'https://api.modrinth.com/v2'
$q = '?loaders=' + [uri]::EscapeDataString('["neoforge"]') + '&game_versions=' + [uri]::EscapeDataString('["1.21.1"]')

$wanted = @(
  'sodium','iris','colorwheel','modernfix','ferrite-core','immediatelyfast','entityculling',
  'jei','jade','appleskin','xaeros-minimap','xaeros-world-map','mouse-tweaks','inventory-profiles-next',
  'sophisticated-backpacks','sophisticated-storage','carry-on','waystones','comforts','ambientsounds','sound-physics-remastered',
  'create','slice-and-dice','copycats','create-deco','create-enchantment-industry',
  'farmers-delight','chefs-delight','brewin-and-chewin',
  'handcrafted','supplementaries','amendments',
  'yungs-better-dungeons','yungs-better-mineshafts','yungs-better-strongholds','yungs-better-desert-temples',
  'yungs-better-jungle-temples','yungs-better-ocean-monuments','yungs-better-witch-huts',
  'yungs-better-nether-fortresses','yungs-better-end-island','yungs-bridges','yungs-extras',
  'ribbits','natures-compass','friends-and-foes-forge','naturalist'
)

# shader packs aren't tied to a game version, so only the newest Iris release is taken
$shaders = @('complementary-reimagined','bsl-shaders','bliss-shader')

$selected = [ordered]@{}   # project_id -> @{project; version}
$pinned = @{}              # project_id -> version_id required by someone
$queue = New-Object System.Collections.Queue
foreach ($s in $wanted) { $queue.Enqueue(@{ id = $s; ver = $null; from = 'lista' }) }

while ($queue.Count) {
  $item = $queue.Dequeue()
  $p = Invoke-RestMethod "$api/project/$($item.id)"
  if ($selected.Contains($p.id)) { continue }
  # always take the newest NeoForge 1.21.1 build; version-pinned deps (e.g. Iris -> Sodium) list old builds
  $r = Invoke-RestMethod "$api/project/$($p.id)/version$q"
  $vs = @($r)
  if ($true) {
    if (-not $vs.Count) { Write-Warning "SEM VERSAO: $($p.slug) (pedido por $($item.from))"; continue }
    $v = ($vs | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1)
    if (-not $v) { $v = $vs[0] }
  }
  $selected[$p.id] = @{ project = $p; version = $v }
  foreach ($d in $v.dependencies) {
    if ($d.dependency_type -eq 'required' -and $d.project_id) {
      $queue.Enqueue(@{ id = $d.project_id; ver = $d.version_id; from = $p.slug })
    }
  }
}

# incompatibilities between selected projects
foreach ($e in $selected.Values) {
  foreach ($d in $e.version.dependencies) {
    if ($d.dependency_type -eq 'incompatible' -and $d.project_id -and $selected.Contains($d.project_id)) {
      Write-Warning "INCOMPATIVEL: $($e.project.slug) x $($selected[$d.project_id].project.slug)"
    }
  }
}

$meta = [xml](Invoke-WebRequest 'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml' -UseBasicParsing).Content
$neo = $meta.metadata.versioning.versions.version | Where-Object { $_ -match '^21\.1\.\d+$' } |
  Sort-Object { [int]($_ -split '\.')[2] } | Select-Object -Last 1

function Map-Side($s) { switch ($s) { 'unsupported' { 'unsupported' } 'optional' { 'optional' } default { 'required' } } }

$files = foreach ($e in $selected.Values) {
  $f = $e.version.files | Where-Object { $_.primary } | Select-Object -First 1
  if (-not $f) { $f = $e.version.files[0] }
  [ordered]@{
    path = "mods/$($f.filename)"
    hashes = [ordered]@{ sha1 = $f.hashes.sha1; sha512 = $f.hashes.sha512 }
    env = [ordered]@{ client = 'required'; server = (Map-Side $e.project.server_side) }
    downloads = @($f.url)
    fileSize = $f.size
  }
}

$sq = '?loaders=' + [uri]::EscapeDataString('["iris"]')
$shaderFiles = foreach ($s in $shaders) {
  $r = Invoke-RestMethod "$api/project/$s/version$sq"
  $v = @($r) | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1
  $f = $v.files | Where-Object { $_.primary } | Select-Object -First 1
  if (-not $f) { $f = $v.files[0] }
  "shader: {0,-26} {1}" -f $s, $v.version_number | Write-Host
  [ordered]@{
    path = "shaderpacks/$($f.filename)"
    hashes = [ordered]@{ sha1 = $f.hashes.sha1; sha512 = $f.hashes.sha512 }
    env = [ordered]@{ client = 'required'; server = 'unsupported' }
    downloads = @($f.url)
    fileSize = $f.size
  }
}

$index = [ordered]@{
  formatVersion = 1
  game = 'minecraft'
  versionId = $Version
  name = 'Aconchego'
  summary = 'Vanilla+ cozy com Create, Farmer''s Delight e exploracao'
  files = @($files) + @($shaderFiles)
  dependencies = [ordered]@{ minecraft = '1.21.1'; neoforge = $neo }
}

$work = Join-Path $env:TEMP "mrpack-build"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work | Out-Null
$json = $index | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $work 'modrinth.index.json'), $json, (New-Object Text.UTF8Encoding $false))
New-Item -ItemType Directory -Force $OutDir | Out-Null
[IO.File]::WriteAllText((Join-Path $OutDir 'modrinth.index.json'), $json, (New-Object Text.UTF8Encoding $false))
$out = Join-Path $OutDir "Aconchego-$Version.mrpack"
Remove-Item $out -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($work, $out)

"NeoForge: $neo"
"Mods: $($selected.Count) (lista: $($wanted.Count))"
$selected.Values | ForEach-Object { "{0,-34} {1}" -f $_.project.slug, $_.version.version_number }
"Saida: $out"
