# drag-test.ps1 - simulate a real mouse drag on the pet window (ASCII only, no BOM needed).
# Why: "the window will not drag" cannot be reproduced by reading code. This moves the
# real cursor: press at (GrabX,GrabY), glide to (EndX,EndY), release.
#
# RED FLAG - measured 2026-10-13: this synthetic drag can NOT move the window.
#   SetCursorPos + mouse_event DOES make the app log a "drag finished" line, but the
#   window stays put, because WPF's DragMove() runs the OS modal move loop which does
#   not follow programmatically injected moves here. So a no-move result from this
#   script proves NOTHING. To answer "can it be dragged", ask the human to drag once
#   and then read the "drag finished" lines in ~/.dsh/pet-window/window.log.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File drag-test.ps1 -GrabX 1705 -GrabY 228 -EndX 1625 -EndY 148
param(
  [Parameter(Mandatory=$true)][int]$GrabX,
  [Parameter(Mandatory=$true)][int]$GrabY,
  [Parameter(Mandatory=$true)][int]$EndX,
  [Parameter(Mandatory=$true)][int]$EndY,
  [int]$Steps = 20
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DshMouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP   = 0x0004;
}
"@

[DshMouse]::SetCursorPos($GrabX, $GrabY) | Out-Null
Start-Sleep -Milliseconds 250
[DshMouse]::mouse_event([DshMouse]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 250
for ($i = 1; $i -le $Steps; $i++) {
  $x = [int]($GrabX + ($EndX - $GrabX) * $i / $Steps)
  $y = [int]($GrabY + ($EndY - $GrabY) * $i / $Steps)
  [DshMouse]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 25
}
Start-Sleep -Milliseconds 200
[DshMouse]::mouse_event([DshMouse]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 300
Write-Output "drag done: ($GrabX,$GrabY) -> ($EndX,$EndY)"
