param(
    [string]$ProcessName,
    [string]$WindowTitle,
    [int]$WindowIndex = 1,
    [Parameter(Mandatory = $true)]
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

public class WslSnapItWindowCapture {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static List<IntPtr> FindWindows(string processName, string titleContains) {
        var results = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) {
                return true;
            }

            var sb = new StringBuilder(1024);
            GetWindowText(hWnd, sb, sb.Capacity);
            var title = sb.ToString();
            if (String.IsNullOrWhiteSpace(title)) {
                return true;
            }

            bool matched = true;
            if (!String.IsNullOrWhiteSpace(titleContains)) {
                matched = title.IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) >= 0;
            }

            if (matched && !String.IsNullOrWhiteSpace(processName)) {
                matched = false;
                try {
                    uint pid;
                    GetWindowThreadProcessId(hWnd, out pid);
                    var proc = Process.GetProcessById((int)pid);
                    matched = proc.ProcessName.Equals(processName, StringComparison.OrdinalIgnoreCase)
                        || (proc.ProcessName + ".exe").Equals(processName, StringComparison.OrdinalIgnoreCase);
                } catch {}
            }

            if (matched) {
                results.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return results;
    }

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@

try { [WslSnapItWindowCapture]::SetProcessDpiAwareness(2) | Out-Null } catch {}
try { [WslSnapItWindowCapture]::SetProcessDPIAware() | Out-Null } catch {}

$windows = [WslSnapItWindowCapture]::FindWindows($ProcessName, $WindowTitle)
if ($windows.Count -lt 1) {
    throw "No matching windows found for process '$ProcessName' title '$WindowTitle'."
}
if ($WindowIndex -lt 1 -or $WindowIndex -gt $windows.Count) {
    throw "WindowIndex $WindowIndex is out of range. Matching windows: $($windows.Count)."
}

$hwnd = $windows[$WindowIndex - 1]
$rect = New-Object WslSnapItWindowCapture+RECT
if (-not [WslSnapItWindowCapture]::GetWindowRect($hwnd, [ref]$rect)) {
    throw "GetWindowRect failed."
}

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) {
    throw "Window has invalid bounds ${width}x${height}."
}

$dir = Split-Path -Parent $OutFile
if ($dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $graphics.GetHdc()
try {
    $ok = [WslSnapItWindowCapture]::PrintWindow($hwnd, $hdc, 2)
} finally {
    $graphics.ReleaseHdc($hdc)
}

try {
    if (-not $ok) {
        throw "PrintWindow failed."
    }
    $bitmap.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output $OutFile
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
