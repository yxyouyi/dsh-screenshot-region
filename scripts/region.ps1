# region.ps1 — one-step region snipper.
#
# The user presses the composer button once, drags a rectangle on a frozen picture of
# the desktop, and only THAT rectangle is produced. There is no intermediate
# full-screen screenshot to look at and no second step: the overlay is the selector.
#
# The whole hide / capture / select / restore sequence happens inside one process, for
# the same reason snip.ps1 does: a hidden window restored by a separate pwsh call can
# stay invisible for a second or more, and a failed restore leaves it hidden for good.
# The restore lives in `finally`, so it cannot be skipped.
#
# Reported as a single JSON line, like the other helpers here.
#
# Usage:
#   powershell -STA -File region.ps1 -Hwnd <handle> -OutFile <png> -HideOwn
#   powershell -STA -File region.ps1 -OutFile <png> -Rect "10,20,300,200"   # headless
#
# Headless mode (`-Rect`) skips the overlay and crops the given screen rectangle, which
# is how this script is verified without a human dragging a box.

param(
  [long]$Hwnd = 0,
  [Parameter(Mandatory = $true)][string]$OutFile,
  # Hide the owning window while the frozen picture is taken.
  [switch]$HideOwn,
  # Extra wait after DwmFlush before the framebuffer is read, in milliseconds.
  [int]$Settle = 250,
  # Give up waiting for a selection after this long.
  [int]$TimeoutSec = 180,
  # "x,y,w,h" in screen pixels: skip the overlay, crop this rectangle.
  [string]$Rect = '',
  # Build the overlay, force one paint pass and exit without showing it. This is the
  # regression test for setup errors that only surface when the window exists.
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Required explicitly: Windows PowerShell 5.1 does not auto-load System.Drawing.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace RGN -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
[DllImport("dwmapi.dll")] public static extern int DwmFlush();
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
  public int length; public int flags; public int showCmd;
  public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
}
'@

function Write-JsonLine([string]$json) { Write-Output $json }

function Write-Ok([string]$file, [int]$x, [int]$y, [int]$w, [int]$h) {
  $safe = ($file -replace '\\', '\\') -replace '"', '\"'
  Write-JsonLine ('{"status":"ok","data":{"file":"' + $safe + '","x":' + $x + ',"y":' + $y +
    ',"width":' + $w + ',"height":' + $h + '}}')
}

function Write-Cancelled { Write-JsonLine '{"status":"cancelled"}' }

function Write-Failed([string]$message) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $message.ToCharArray()) {
    $c = [int]$ch
    if ($c -ge 0x20 -and $c -le 0x7E) {
      if ($ch -eq '"' -or $ch -eq '\') { [void]$sb.Append('\') }
      [void]$sb.Append($ch)
    }
  }
  Write-JsonLine ('{"status":"error","error":"' + $sb.ToString() + '"}')
}

function Save-Crop($bmp, [int]$x, [int]$y, [int]$w, [int]$h) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
  $crop = $bmp.Clone($rect, $bmp.PixelFormat)
  try { $crop.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png) }
  finally { $crop.Dispose() }
}

# Event handlers run in their own scope, so every value they touch is kept in a
# script-scoped bag rather than a local variable of the enclosing block.
$script:rgnHidden = $false
# State the owning window had before it was hidden (GetWindowPlacement showCmd).
$script:rgnShowCmd = 1

function Restore-OwnWindow {
  if (-not $script:rgnHidden -or $Hwnd -eq 0) { return }
  $h = [IntPtr]$Hwnd
  # Restore the state the window had BEFORE it was hidden. SW_RESTORE returns a
  # maximized window at normal size and un-minimizes a minimized one, which is the
  # jump the user saw; showing by the recorded showCmd keeps the original state.
  switch ($script:rgnShowCmd) {
    3 { [void][RGN.Native]::ShowWindow($h, 3) }        # SW_SHOWMAXIMIZED
    2 { [void][RGN.Native]::ShowWindow($h, 6) }        # SW_MINIMIZE
    default { [void][RGN.Native]::ShowWindow($h, 1) }  # SW_SHOWNORMAL
  }
  if ($script:rgnShowCmd -ne 2) {
    # Bring it back above the other windows and give focus back; a minimized window
    # has no frame to raise, so this is skipped for that case.
    [void][RGN.Native]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003)  # TOPMOST | NOSIZE | NOMOVE
    [void][RGN.Native]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0003)  # NOTOPMOST
    [void][RGN.Native]::SetForegroundWindow($h)
  }
  $script:rgnHidden = $false
}

try {
  [void][RGN.Native]::SetProcessDPIAware()
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

  if ($HideOwn -and $Hwnd -ne 0) {
    # Record the exact state first. SW_RESTORE on a maximized window returns it at
    # normal size, which reads as "the window shrank by itself".
    $wp = New-Object RGN.Native+WINDOWPLACEMENT
    $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
    if ([RGN.Native]::GetWindowPlacement([IntPtr]$Hwnd, [ref]$wp)) { $script:rgnShowCmd = $wp.showCmd }
    [void][RGN.Native]::ShowWindow([IntPtr]$Hwnd, 0)   # SW_HIDE
    $script:rgnHidden = $true
    # SW_HIDE only clears WS_VISIBLE; DWM removes the pixels asynchronously. Without
    # DwmFlush + a margin the frozen picture shows the window as a torn ghost.
    [void][RGN.Native]::DwmFlush()
    if ($Settle -gt 0) { Start-Sleep -Milliseconds $Settle }
  }

  $shot = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($shot)
  try {
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, (New-Object System.Drawing.Size($vs.Width, $vs.Height)), [System.Drawing.CopyPixelOperation]::SourceCopy)
  } finally { $g.Dispose() }

  # ── headless mode: crop a given rectangle, no UI ──────────────────────────────
  if ($Rect -ne '') {
    $parts = $Rect.Split(',')
    if ($parts.Count -ne 4) { throw 'region.ps1: -Rect needs "x,y,w,h".' }
    $rx = [int]$parts[0]; $ry = [int]$parts[1]; $rw = [int]$parts[2]; $rh = [int]$parts[3]
    $rx = [Math]::Max(0, [Math]::Min($rx, $vs.Width - 1))
    $ry = [Math]::Max(0, [Math]::Min($ry, $vs.Height - 1))
    $rw = [Math]::Max(1, [Math]::Min($rw, $vs.Width - $rx))
    $rh = [Math]::Max(1, [Math]::Min($rh, $vs.Height - $ry))
    Save-Crop $shot $rx $ry $rw $rh
    $shot.Dispose()
    Restore-OwnWindow
    Write-Ok $OutFile $rx $ry $rw $rh
    return
  }

  # ── interactive overlay ──────────────────────────────────────────────────────
  $form = New-Object System.Windows.Forms.Form
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Bounds = $vs
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.KeyPreview = $true
  $form.BackColor = [System.Drawing.Color]::Black
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  # Form.DoubleBuffered is protected: assigning it directly from PowerShell throws
  # "The property 'DoubleBuffered' cannot be found on this object", which is the whole
  # error text the user saw. Reach it through reflection, and keep going without it —
  # double buffering only removes flicker.
  try {
    $buffered = [System.Windows.Forms.Form].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    if ($buffered -ne $null) { $buffered.SetValue($form, $true) }
  } catch { }

  $script:rgnShot = $shot
  $script:rgnVs = $vs
  $script:rgnFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
  $script:rgnBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $script:rgnApp = @{ start = $null; current = $null; result = $null }

  $form.Add_Paint({
    param($sender, $e)
    $vs2 = $script:rgnVs
    $e.Graphics.DrawImageUnscaled($script:rgnShot, 0, 0)
    $dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
    try { $e.Graphics.FillRectangle($dim, 0, 0, $vs2.Width, $vs2.Height) } finally { $dim.Dispose() }
    $app = $script:rgnApp
    if ($app.start -ne $null -and $app.current -ne $null) {
      $x1 = [Math]::Min($app.start.X, $app.current.X)
      $y1 = [Math]::Min($app.start.Y, $app.current.Y)
      $w = [Math]::Abs($app.current.X - $app.start.X)
      $h = [Math]::Abs($app.current.Y - $app.start.Y)
      if ($w -gt 0 -and $h -gt 0) {
        $rect = New-Object System.Drawing.Rectangle($x1, $y1, $w, $h)
        $e.Graphics.DrawImage($script:rgnShot, $rect, $x1, $y1, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0, 174, 255), 1)
        try { $e.Graphics.DrawRectangle($pen, $x1, $y1, $w, $h) } finally { $pen.Dispose() }
        $e.Graphics.DrawString(("$w x $h"), $script:rgnFont, $script:rgnBrush, [float]($x1 + 4), [float]([Math]::Max(0, $y1 - 22)))
      }
    }
    $e.Graphics.DrawString('拖动鼠标框选要截取的范围 · 松开鼠标完成 · Esc 或右键取消', $script:rgnFont, $script:rgnBrush, [float]16, [float]16)
  })

  $form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:rgnApp.start = $e.Location
      $script:rgnApp.current = $e.Location
      $sender.Invalidate()
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $sender.Close()
    }
  })

  $form.Add_MouseMove({
    param($sender, $e)
    if ($script:rgnApp.start -ne $null) {
      $script:rgnApp.current = $e.Location
      $sender.Invalidate()
    }
  })

  $form.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $script:rgnApp.start -eq $null) { return }
    $script:rgnApp.current = $e.Location
    $w = [Math]::Abs($script:rgnApp.current.X - $script:rgnApp.start.X)
    $h = [Math]::Abs($script:rgnApp.current.Y - $script:rgnApp.start.Y)
    # A click without a drag must not select anything: requiring a real box is what
    # keeps a stray click from turning into a capture.
    if ($w -lt 8 -or $h -lt 8) {
      $script:rgnApp.start = $null
      $script:rgnApp.current = $null
      $sender.Invalidate()
      return
    }
    $script:rgnApp.result = @{
      x = [Math]::Min($script:rgnApp.start.X, $script:rgnApp.current.X)
      y = [Math]::Min($script:rgnApp.start.Y, $script:rgnApp.current.Y)
      width = $w
      height = $h
    }
    $sender.Close()
  })

  $form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() }
  })

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(5000, $TimeoutSec * 1000)
  # Event handlers do not see this block's locals, so the form is kept script-scoped.
  $script:rgnForm = $form
  $timer.Add_Tick({ param($sender, $e) $sender.Stop(); if ($script:rgnForm -ne $null) { $script:rgnForm.Close() } })

  $timer.Start()
  if ($SelfTest) {
    # Force the form into existence and through one paint pass, without ever showing
    # it. A bad property assignment or a scope mistake in the Paint handler fails here
    # instead of on the user's screen.
    $form.CreateControl()
    $probe = New-Object System.Drawing.Bitmap(240, 160)
    try {
      $form.DrawToBitmap($probe, (New-Object System.Drawing.Rectangle(0, 0, 240, 160)))
    } finally { $probe.Dispose() }
    $timer.Stop()
    $timer.Dispose()
    $script:rgnShot.Dispose()
    $form.Dispose()
    Restore-OwnWindow
    Write-JsonLine '{"status":"ok","data":{"selfTest":true}}'
    return
  }
  [void]$form.ShowDialog()
  $timer.Stop()
  $timer.Dispose()

  if ($script:rgnApp.result -eq $null) {
    $script:rgnShot.Dispose()
    Restore-OwnWindow
    Write-Cancelled
  } else {
    $x = [int]$script:rgnApp.result.x
    $y = [int]$script:rgnApp.result.y
    $w = [int]$script:rgnApp.result.width
    $h = [int]$script:rgnApp.result.height
    Save-Crop $script:rgnShot $x $y $w $h
    $script:rgnShot.Dispose()
    Restore-OwnWindow
    Write-Ok $OutFile $x $y $w $h
  }
}
catch {
  Write-Failed $_.Exception.Message
  exit 1
}
finally {
  Restore-OwnWindow
}
