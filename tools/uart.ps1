param([string]$Port = "COM3", [int]$Seconds = 5)
$p = New-Object System.IO.Ports.SerialPort $Port, 115200
$p.ReadBufferSize = 1048576
$p.Open(); Start-Sleep $Seconds; $p.ReadExisting(); $p.Close()
