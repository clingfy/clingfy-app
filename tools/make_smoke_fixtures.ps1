#Requires -Version 7
<#
.SYNOPSIS
  Builds synthetic .clingfyproj bundles for the on-device smoke matrix rows that
  need a specific AUDIO LAYOUT rather than a specific recording.

.DESCRIPTION
  Rows 18 and 19 of docs/windows-beta-release-checklist.md are blocked less by
  difficulty than by setup: to check "Voice Cleanup is hidden on a mic-less
  recording" you first need a mic-less recording, and to check "mic-only gain
  raises the mic and leaves system audio steady" you need a recording whose mic
  and system audio are separable BY EAR. Producing those by hand means finding a
  quiet room, a loopback source, and getting the levels right.

  This generates them deterministically instead:

    smoke-system-audio-only   system sidecar, NO mic sidecar.
                              Row 18: Voice Cleanup control must be HIDDEN and
                              the "no mic audio" notice shown.

    smoke-separated-mic-system  mic + system sidecars, deliberately DIFFERENT
                              pitches at DIFFERENT levels.
                              Row 18 (second half): the control must APPEAR.
                              Row 19: raising mic-only gain must raise the low
                              tone while the high tone stays put.

  The two tones are the whole point. A single mixed track cannot demonstrate
  "mic only" — you need to hear one move and the other not. Mic is the LOW tone
  and starts quiet (-20 dBFS) so there is real headroom to raise before it
  clips; system is the HIGH tone at a steady -12 dBFS.

  The video is four flat colour segments so a cut or a drag-reorder is
  verifiable at a glance, which also serves the first half of row 19.

.NOTES
  Requires ffmpeg on PATH.

  The bundles are written to the DEV channel's recordings root by default
  (%LOCALAPPDATA%\Clingfy Dev\recordings) because that is where the dev build
  looks after the D9 per-channel identity split. Pass -OutputRoot to override.

  `hasMicAudio` is gated on the sidecar being DECODABLE (ProbeDecodableAudio in
  preview_router.cpp), not merely present — which is why these are real encoded
  AAC files and not empty placeholders.
#>
[CmdletBinding()]
param(
  # Where the .clingfyproj bundles land. Defaults to the dev channel's root.
  [string]$OutputRoot,

  # Seconds of media. Four colour segments are derived from this.
  [int]$DurationSeconds = 12,

  # Overwrite existing bundles of the same name.
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) { Fail 'ffmpeg not found on PATH. winget install Gyan.FFmpeg' }

if (-not $OutputRoot) {
  $OutputRoot = Join-Path $env:LOCALAPPDATA 'Clingfy Dev\recordings'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Step "Output root: $OutputRoot"

$segment = [math]::Max(1, [int]($DurationSeconds / 4))
$total = $segment * 4
$rate = 48000

# --- media synthesis ---------------------------------------------------------

function New-ColourVideo([string]$path, [int]$segSeconds) {
  # Four flat colours, one per segment. No drawtext: it needs a font file on
  # Windows and fails in ways that are tedious to diagnose, and colour alone
  # already makes a reorder obvious.
  $colours = @('red', 'green', 'blue', 'orange')
  $inputs = @()
  foreach ($c in $colours) {
    $inputs += @('-f', 'lavfi', '-t', "$segSeconds", '-i', "color=c=${c}:s=1280x720:r=30")
  }
  $filter = '[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0[v]'
  & ffmpeg -y -loglevel error @inputs -filter_complex $filter -map '[v]' `
    -c:v libx264 -pix_fmt yuv420p -preset veryfast $path
  if ($LASTEXITCODE -ne 0) { Fail "ffmpeg failed building $path" }
}

function New-Tone([string]$path, [int]$freq, [double]$dbfs, [int]$seconds) {
  # AAC in m4a: the same container/codec the recorder writes its sidecars in,
  # so ProbeDecodableAudio sees the shape it expects.
  & ffmpeg -y -loglevel error -f lavfi -t "$seconds" `
    -i "sine=frequency=${freq}:sample_rate=${rate}" `
    -af "volume=${dbfs}dB" -c:a aac -b:a 128k -ac 2 $path
  if ($LASTEXITCODE -ne 0) { Fail "ffmpeg failed building $path" }
}

function New-PremixedScreen([string]$videoPath, [string]$micPath, [string]$sysPath, [string]$outPath) {
  # screen.mov carries the PREMIX, exactly as the recorder produces it: the
  # sidecars are additional, not a replacement. Passthrough playback uses this.
  if ($micPath) {
    & ffmpeg -y -loglevel error -i $videoPath -i $micPath -i $sysPath `
      -filter_complex '[1:a][2:a]amix=inputs=2:duration=shortest:normalize=0[a]' `
      -map '0:v' -map '[a]' -c:v copy -c:a aac -b:a 160k -f mov $outPath
  } else {
    & ffmpeg -y -loglevel error -i $videoPath -i $sysPath `
      -map '0:v' -map '1:a' -c:v copy -c:a aac -b:a 160k -f mov $outPath
  }
  if ($LASTEXITCODE -ne 0) { Fail "ffmpeg failed building $outPath" }
}

# --- bundle writer -----------------------------------------------------------

function New-Bundle {
  param(
    [string]$Name,
    [bool]$WithMic,
    [string]$Description
  )

  $bundle = Join-Path $OutputRoot "$Name.clingfyproj"
  if (Test-Path $bundle) {
    if (-not $Force) { Fail "$bundle exists. Pass -Force to overwrite." }
    Remove-Item -Recurse -Force $bundle
  }

  Step "Building $Name"
  Note $Description

  $capture = Join-Path $bundle 'capture'
  New-Item -ItemType Directory -Force -Path $capture | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'post') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'derived') | Out-Null

  $tmpVideo = Join-Path $env:TEMP "clingfy_fixture_v_$([guid]::NewGuid().ToString('N')).mp4"
  try {
    New-ColourVideo -path $tmpVideo -segSeconds $segment

    $sysPath = Join-Path $capture 'system.m4a'
    # HIGH tone, steady reference level. This is the one that must NOT move
    # when mic-only gain is raised.
    New-Tone -path $sysPath -freq 880 -dbfs -12 -seconds $total

    $micPath = $null
    if ($WithMic) {
      $micPath = Join-Path $capture 'mic.m4a'
      # LOW tone, deliberately quiet so there is headroom to raise it without
      # immediately clipping — otherwise "raise the gain" has nothing to show.
      New-Tone -path $micPath -freq 440 -dbfs -20 -seconds $total
    }

    New-PremixedScreen -videoPath $tmpVideo -micPath $micPath -sysPath $sysPath `
      -outPath (Join-Path $capture 'screen.mov')
  } finally {
    Remove-Item -Force $tmpVideo -ErrorAction SilentlyContinue
  }

  # An empty manual-zoom list: the key is referenced by the manifest, and a
  # well-formed empty file is friendlier than an absent one.
  '[]' | Set-Content -Path (Join-Path $capture 'zoom.manual.json') -Encoding utf8 -NoNewline

  $created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $micKey = if ($WithMic) { "`n    `"micAudio`": `"capture/mic.m4a`"," } else { '' }

  # Mirrors BuildManifestJson in recording_project_writer.cpp. schemaVersion 2;
  # sidecar keys are emitted ONLY for sidecars that exist, which is what the
  # reader's existence gate expects.
  $manifest = @"
{
  "schemaVersion": 2,
  "projectId": "$Name",
  "createdAt": "$created",
  "updatedAt": "$created",
  "displayName": "$Name",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "cursorData": "capture/cursor.json",$micKey
    "systemAudio": "capture/system.m4a",
    "zoomManual": "capture/zoom.manual.json"
  },
  "post": {
    "state": "post/state.json",
    "thumbnail": "post/thumbnail.jpg"
  },
  "derived": {
    "waveform": "derived/waveform.json"
  },
  "exportHistory": []
}
"@
  $manifest | Set-Content -Path (Join-Path $bundle 'project.json') -Encoding utf8

  # micActive drives the METADATA FALLBACK gate (used when no decodable sidecar
  # is found). Keeping it truthful means the fixture behaves the same whichever
  # branch the reader takes.
  $micActive = if ($WithMic) { 'true' } else { 'false' }
  $meta = @"
{
  "width": 1280,
  "height": 720,
  "fps": 30,
  "framesReceived": $($total * 30),
  "framesDropped": 0,
  "audioSamplesWritten": $($total * $rate),
  "micActive": $micActive,
  "loopbackActive": true,
  "cursorEnabled": false,
  "targetType": "display",
  "editorSeed": null,
  "platform": "windows"
}
"@
  $meta | Set-Content -Path (Join-Path $capture 'screen.meta.json') -Encoding utf8

  $size = [math]::Round(((Get-ChildItem $bundle -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
  Note "$bundle  (${size} MB)"
  return $bundle
}

$a = New-Bundle -Name 'smoke-system-audio-only' -WithMic $false `
  -Description 'Row 18: system audio only, no mic sidecar. Voice Cleanup must be HIDDEN.'

$b = New-Bundle -Name 'smoke-separated-mic-system' -WithMic $true `
  -Description 'Rows 18/19: mic 440Hz @ -20dBFS + system 880Hz @ -12dBFS. Control must SHOW; mic-only gain must move the LOW tone only.'

Write-Host ''
Step 'Done'
Write-Host @"
    Open each from the app (or right-click the bundle folder).

    smoke-system-audio-only
      Row 18  -> post > Audio: Voice Cleanup control HIDDEN, "no mic audio" notice shown.

    smoke-separated-mic-system
      Row 18  -> post > Audio: Voice Cleanup control VISIBLE.
      Row 19  -> raise mic gain: the LOW (440 Hz) tone gets louder, the HIGH
                 (880 Hz) tone does NOT. If both move, gain is hitting the
                 premix instead of the mic sidecar.
      Row 19  -> cut the middle, or drag-reorder: the colour order (red, green,
                 blue, orange) makes the result obvious.
"@ -ForegroundColor Gray
