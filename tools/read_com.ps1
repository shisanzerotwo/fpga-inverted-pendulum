# Read a serial port for N seconds and print each byte (HEX) with a timestamp.
# Usage: powershell -File read_com.ps1 COM9 115200 6
# 2026-10-01 measured: FPGA uart_tx (F12) bytes arrive on COM9 (FTDIBUS VID_0403 PID_6010).
# COM7 (VID_0D28 DAPLink CDC) carries the GD32 firmware's own banner text, not FPGA output.
# Keep this file ASCII-only: Windows PowerShell 5 reads BOM-less UTF-8 as GBK.
param([string]$Port = "COM9", [int]$Baud = 115200, [int]$Seconds = 6)
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
try {
    $sp.Open()
    $sp.DiscardInBuffer()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $n = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try {
            $b = $sp.ReadByte()
            if ($b -ge 0) { $n++; "{0,7:F3}s  0x{1:X2}" -f $sw.Elapsed.TotalSeconds, $b }
        } catch [System.TimeoutException] {}
    }
    "total bytes: $n in $Seconds s"
} finally { if ($sp.IsOpen) { $sp.Close() } }
