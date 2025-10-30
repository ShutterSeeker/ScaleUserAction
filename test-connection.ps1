# Test SQL Server connection using Windows Authentication
# Run this on the IIS server as the service account
#
# Usage:
#   .\test-connection.ps1 -ServerName "SQL01" -DatabaseName "SCALE_DB"
#
# To run as specific service account:
#   runas /user:DOMAIN\ServiceAccount "powershell.exe -File test-connection.ps1"

param(
    [string]$ServerName = "YOUR_SERVER_HERE",
    [string]$DatabaseName = "YOUR_DATABASE_HERE"
)

Write-Host "Testing SQL Connection with Windows Authentication" -ForegroundColor Yellow
Write-Host "Server: $ServerName" -ForegroundColor Gray
Write-Host "Database: $DatabaseName" -ForegroundColor Gray
Write-Host "Running as: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Gray
Write-Host ""

$connectionString = "Server=$ServerName;Database=$DatabaseName;Integrated Security=true;TrustServerCertificate=True;"

try {
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    
    Write-Host "✅ Connection successful!" -ForegroundColor Green
    Write-Host ""
    
    # Get connection info
    $command = $connection.CreateCommand()
    $command.CommandText = "SELECT SYSTEM_USER AS [ConnectedAs], DB_NAME() AS [Database], @@VERSION AS [SQLVersion]"
    
    $reader = $command.ExecuteReader()
    if ($reader.Read()) {
        Write-Host "Connected as: " -NoNewline -ForegroundColor White
        Write-Host $reader['ConnectedAs'] -ForegroundColor Cyan
        
        Write-Host "Database: " -NoNewline -ForegroundColor White
        Write-Host $reader['Database'] -ForegroundColor Cyan
        
        $sqlVersion = $reader['SQLVersion'].ToString().Split("`n")[0]
        Write-Host "SQL Version: " -NoNewline -ForegroundColor White
        Write-Host $sqlVersion -ForegroundColor Cyan
    }
    $reader.Close()
    
    # Test stored procedure execution permission
    Write-Host ""
    Write-Host "Testing stored procedure permission..." -ForegroundColor Yellow
    
    $command.CommandText = @"
        IF EXISTS (SELECT 1 FROM sys.procedures WHERE name = 'usp_UserAction')
        BEGIN
            SELECT 'Found' AS Status
        END
        ELSE
        BEGIN
            SELECT 'NotFound' AS Status
        END
"@
    
    $reader = $command.ExecuteReader()
    if ($reader.Read()) {
        $status = $reader['Status']
        if ($status -eq 'Found') {
            Write-Host "✅ Stored procedure 'usp_UserAction' exists" -ForegroundColor Green
        }
        else {
            Write-Host "⚠️  Stored procedure 'usp_UserAction' not found" -ForegroundColor Yellow
            Write-Host "   Deploy usp_UserAction.sql to the database" -ForegroundColor Gray
        }
    }
    $reader.Close()
    
    $connection.Close()
    
    Write-Host ""
    Write-Host "✅ All tests passed!" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "❌ Connection failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
    Write-Host "1. Verify SQL Server name and database name are correct" -ForegroundColor Gray
    Write-Host "2. Ensure Windows account '$env:USERDOMAIN\$env:USERNAME' has SQL Server login" -ForegroundColor Gray
    Write-Host "3. Grant database access: CREATE USER [$env:USERDOMAIN\$env:USERNAME] FOR LOGIN [$env:USERDOMAIN\$env:USERNAME]" -ForegroundColor Gray
    Write-Host "4. Check SQL Server allows Windows Authentication" -ForegroundColor Gray
    Write-Host "5. Verify firewall allows connection to SQL Server port (default 1433)" -ForegroundColor Gray
    
    exit 1
}
