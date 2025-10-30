# Windows Authentication Deployment Guide

This guide provides step-by-step instructions for deploying the SCALE User Action API with Windows Authentication.

## Prerequisites

- [ ] IIS server with .NET 8 Hosting Bundle installed
- [ ] Service account with SQL Server access (same account used by SCALE apps)
- [ ] SQL Server permissions for the service account
- [ ] Administrative access to IIS

## Deployment Steps

### 1. Build and Publish

```powershell
# In the project directory
dotnet restore
dotnet build -c Release
dotnet publish -c Release -o C:\Publish\ScaleUserAction
```

### 2. Install .NET 8 Hosting Bundle (if needed)

Check if already installed:
```powershell
dotnet --list-runtimes | Select-String "AspNetCore.App 8"
```

If not found:
1. Download from https://dotnet.microsoft.com/download/dotnet/8.0
2. Run the installer
3. Execute: `iisreset`

### 3. Verify AspNetCoreModuleV2 Installation

```powershell
Get-WebGlobalModule | Where-Object { $_.Name -like "*AspNetCore*" }
```

Expected output: `AspNetCoreModuleV2` should be listed.

### 4. Configure IIS Application Pool

```powershell
# Import IIS module
Import-Module WebAdministration

# Find the service account used by SCALE
Get-IISAppPool | Where-Object { $_.Name -like "*SCALE*" } | 
    Select-Object Name, @{Name="Identity";Expression={$_.ProcessModel.UserName}}

# Create new app pool with same identity
$appPoolName = "ScaleUserAction"
$serviceAccount = "DOMAIN\ServiceAccount"  # Replace with actual account

New-WebAppPool -Name $appPoolName
Set-ItemProperty -Path "IIS:\AppPools\$appPoolName" -Name "processModel.identityType" -Value 3
Set-ItemProperty -Path "IIS:\AppPools\$appPoolName" -Name "processModel.userName" -Value $serviceAccount
Set-ItemProperty -Path "IIS:\AppPools\$appPoolName" -Name "processModel.password" -Value "PASSWORD"
Set-ItemProperty -Path "IIS:\AppPools\$appPoolName" -Name "managedRuntimeVersion" -Value ""
```

### 5. Create IIS Application

```powershell
# Create application under SCALE site
$siteName = "SCALE"  # Replace with your IIS site name
$appName = "UserAction"
$physicalPath = "C:\Publish\ScaleUserAction"

New-WebApplication -Name $appName -Site $siteName -PhysicalPath $physicalPath -ApplicationPool $appPoolName
```

### 6. Configure Windows Authentication

```powershell
# Enable Windows Authentication, disable Anonymous
Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" `
    -Name "enabled" -Value $true -PSPath "IIS:\" -Location "$siteName/$appName"

Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" `
    -Name "enabled" -Value $false -PSPath "IIS:\" -Location "$siteName/$appName"
```

### 7. Update web.config

Edit `C:\Publish\ScaleUserAction\web.config`:

```xml
<environmentVariable name="ConnectionStrings__DefaultConnection" 
    value="Server=YOUR_SQL_SERVER;Database=YOUR_DATABASE;Integrated Security=true;TrustServerCertificate=True;" />
```

Replace:
- `YOUR_SQL_SERVER` with your SQL Server instance name
- `YOUR_DATABASE` with your SCALE database name

### 8. Create Logs Directory

```powershell
New-Item -Path "C:\Publish\ScaleUserAction\logs" -ItemType Directory -Force

# Grant write permissions to service account
$acl = Get-Acl "C:\Publish\ScaleUserAction\logs"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $serviceAccount, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl "C:\Publish\ScaleUserAction\logs" $acl
```

### 9. Grant SQL Server Permissions

```sql
USE [YourDatabase];
GO

-- Check if login exists
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'DOMAIN\ServiceAccount')
BEGIN
    CREATE LOGIN [DOMAIN\ServiceAccount] FROM WINDOWS;
    PRINT 'Login created.'
END
ELSE
    PRINT 'Login already exists.'
GO

-- Create database user
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'DOMAIN\ServiceAccount')
BEGIN
    CREATE USER [DOMAIN\ServiceAccount] FOR LOGIN [DOMAIN\ServiceAccount];
    PRINT 'User created.'
END
ELSE
    PRINT 'User already exists.'
GO

-- Grant execute permission on stored procedure
GRANT EXECUTE ON dbo.usp_UserAction TO [DOMAIN\ServiceAccount];
PRINT 'EXECUTE permission granted.'
GO

-- Optional: Grant broader permissions if needed
-- ALTER ROLE db_datareader ADD MEMBER [DOMAIN\ServiceAccount];
-- ALTER ROLE db_datawriter ADD MEMBER [DOMAIN\ServiceAccount];
```

### 10. Deploy Updated Stored Procedure

Run `usp_UserAction.sql` in your database to add the `@userName` parameter.

### 11. Optional: Create Audit Table

Run `create_audit_table.sql` to create the audit logging table, then uncomment audit logging lines in `usp_UserAction.sql`.

### 12. Test the Deployment

```powershell
# Test health endpoint (should work without auth)
Invoke-WebRequest -Uri "https://your-server/UserAction/health" -UseBasicParsing

# Test authenticated endpoint (use current Windows credentials)
Invoke-WebRequest -Uri "https://your-server/UserAction/ExecProc?action=Test" `
    -Method POST `
    -Body '{"internalID":"123","changeValue":"test"}' `
    -ContentType "application/json" `
    -UseDefaultCredentials

# Check logs for any errors
Get-Content "C:\Publish\ScaleUserAction\logs\stdout*.log" -Tail 50
```

### 13. Verify Windows Authentication

Check the logs or add temporary logging to verify the authenticated user:

```powershell
# Look for user identity in application logs
Get-EventLog -LogName Application -Source "IIS AspNetCore Module" -Newest 10
```

### 14. Recycle Application Pool

```powershell
Restart-WebAppPool -Name $appPoolName
```

## Troubleshooting

### Issue: 401 Unauthorized

**Cause**: Windows Authentication not working

**Solutions**:
1. Verify Windows Authentication is enabled in IIS
2. Check that Anonymous Authentication is disabled
3. Ensure `forwardWindowsAuthToken="true"` in web.config
4. Verify Application Pool identity is correct
5. Check Windows Event Viewer for authentication errors

### Issue: 500 Internal Server Error

**Cause**: Database connection failure

**Solutions**:
1. Check connection string in web.config
2. Verify service account has SQL Server login and database permissions
3. Test SQL connection from server using service account:
   ```powershell
   # Run as service account
   sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -E -Q "SELECT SYSTEM_USER"
   ```
4. Check stdout logs in `logs\` folder

### Issue: AspNetCoreModuleV2 not found

**Cause**: .NET 8 Hosting Bundle not installed

**Solution**:
1. Install Hosting Bundle from Microsoft
2. Run `iisreset`
3. Verify: `Get-WebGlobalModule | Where-Object { $_.Name -like "*AspNetCore*" }`

### Issue: Cannot read configuration file

**Cause**: File permissions

**Solution**:
```powershell
# Grant read permissions to IIS_IUSRS
$path = "C:\Publish\ScaleUserAction"
$acl = Get-Acl $path
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "IIS_IUSRS", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl $path $acl
```

## Verification Checklist

- [ ] .NET 8 Hosting Bundle installed
- [ ] AspNetCoreModuleV2 registered in IIS
- [ ] Application Pool created with correct service account
- [ ] Windows Authentication enabled, Anonymous disabled
- [ ] SQL Server permissions granted to service account
- [ ] Connection string updated in web.config
- [ ] Logs directory created with write permissions
- [ ] `/health` endpoint returns `{"status":"ok"}`
- [ ] Test POST returns proper authentication
- [ ] Stored procedure accepts `@userName` parameter
- [ ] SCALE dialog configured with `UseDefaultCredentials=true`

## Security Notes

✅ **No credentials in config files** - Uses Windows Authentication only  
✅ **Principle of least privilege** - Service account has minimum required SQL permissions  
✅ **Encrypted in transit** - HTTPS enforced via HSTS  
✅ **Per-user auditing** - `@userName` tracks who performed each action  
✅ **Optional audit table** - Complete action logging available  

## Next Steps

1. Test with SCALE dialog integration
2. Monitor logs for any authentication issues
3. Enable audit table logging if required
4. Configure additional actions in `usp_UserAction`
5. Set `ASPNETCORE_ENVIRONMENT` to "Production" in web.config for production deployment

