# Deployment Guide - SCALE User Action API

## Prerequisites

- IIS server with **.NET 8 Hosting Bundle** installed
  - Download: https://dotnet.microsoft.com/download/dotnet/8.0
  - After installation, run: `iisreset`

## Deployment Steps

### 1. Clone Repository in Visual Studio

```powershell
git clone https://github.com/ShutterSeeker/ScaleUserAction.git
cd ScaleUserAction
```

### 2. Configure Connection String

Update **`appsettings.json`** with your environment details:

```json
{
    "Logging": {
        "LogLevel": {
            "Default": "Warning",
            "Microsoft.AspNetCore": "Warning"
        }
    },
    "AllowedHosts": "your-scale-server.com",
    "ConnectionStrings": {
        "DefaultConnection": "Server=YOUR_SQL_SERVER;Database=YOUR_DATABASE;User Id=YOUR_SQL_USER;Password=YOUR_SQL_PASSWORD;TrustServerCertificate=True;"
    }
}
```

Update **`web.config`** environment variable (optional - overrides appsettings.json):

```xml
<environmentVariable name="ConnectionStrings__DefaultConnection" 
    value="Server=YOUR_SQL_SERVER;Database=YOUR_DATABASE;User Id=YOUR_SQL_USER;Password=YOUR_SQL_PASSWORD;TrustServerCertificate=True;" />
```

### 3. Build and Publish

In Visual Studio:
- Build → **Publish**
- Choose **Folder** profile
- Target location: `C:\Program Files\Manhattan Associates\ILS\2020\Services\UserAction`
- Click **Publish**

### 4. Create IIS Application Pool

1. Application pools → Right-click → **Add Application Pool...**
2. Name: `ScaleUserAction`
3. Right click `ScaleUserAction` → **Advanced settings**
4. Identity → `...` → Select `Custom Account` → `ILSSRV`
5. Enter ILSSRV credentials

### 5. Create IIS Application

1. Expand your site → Right-click → **Add Application**
2. Alias: `UserAction`
3. Application pool: `ScaleUserAction`
4. Physical path: `C:\Program Files\Manhattan Associates\ILS\2020\Services\UserAction`

### 6. Configure IIS Authentication

In IIS Manager:
1. Select **UserAction** application
2. Double-click **Authentication**
3. **Enable** Anonymous Authentication
4. **Disable** Windows Authentication

### 7. Grant SQL Server Permissions

Run on your SQL Server (replace placeholders with actual account from web.config):

```sql
-- Grant permissions
ALTER ROLE [db_datareader] ADD MEMBER [YOUR_SQL_USER];
ALTER ROLE [db_datawriter] ADD MEMBER [YOUR_SQL_USER];
GRANT EXECUTE ON SCHEMA::[dbo] TO [YOUR_SQL_USER];
GO
```

### 8. Deploy Stored Procedure

Run **`usp_UserAction.sql`** on your SCALE database to create/update the stored procedure.

### 9. Test Deployment

```powershell
# Test health endpoint
Invoke-WebRequest -Uri "https://your-server/UserAction/health" -UseBasicParsing
```

Check logs at: `C:\Program Files\Manhattan Associates\ILS\2020\Services\UserAction\logs\stdout_*.log`

## SCALE Integration

Configure your SCALE dialog button with:

```
Event: _webUi.insightListPaneActions.modalDialogPerformPostForSelection
Parameters:
  - POSTServiceURL=/UserAction/ExecProc?action=YourActionName
  - PostData_Grid_YourGrid_internalID=INTERNAL_ID_FIELD
  - PostData_Input_YourEditor_changeValue=EditorValue
  - ModalDialogName=YourDialogName
  - UseDefaultCredentials=true
```

## Troubleshooting

**500 Error - Database connection failed**
- Verify connection string in web.config
- Check SQL Server permissions for the SQL user account
- Test SQL connection from the IIS server

**No logs generated**
- Verify `logs` folder exists and has write permissions
- Check Windows Event Viewer → Application logs for ASP.NET Core errors

**User showing as "Anonymous"**
- SCALE sends username in `UserName` HTTP header - this is automatically captured
- Check that SCALE dialog has `UseDefaultCredentials=true`

## Production Checklist

- [ ] .NET 8 Hosting Bundle installed on IIS server
- [ ] `appsettings.json` updated with production connection string
- [ ] `web.config` updated with production connection string (if overriding)
- [ ] Application published to `C:\Program Files\Manhattan Associates\ILS\2020\Services\UserAction`
- [ ] IIS Application Pool created with ILSSRV identity
- [ ] IIS Application created under SCALE site
- [ ] Anonymous Authentication enabled, Windows Authentication disabled
- [ ] SQL Server permissions granted to connection string user
- [ ] `usp_UserAction.sql` deployed to database
- [ ] Health endpoint returns `{"status":"ok"}`
- [ ] Test API call succeeds
- [ ] SCALE dialog configured and tested

