# SCALE User Action API

This API provides a generic endpoint for Manhattan SCALE, allowing user input from dialog boxes (like the "update priority" in Work Insight) to be passed alongside internal IDs to identify the record(s) to update.

## Features

This project lets you easily add custom actions to your Manhattan SCALE web app. With this tool, you can:
- Edit any table in SCALE using simple user input from a dialog box—no coding required for each new action!
- Works directly with your existing SCALE web app and dialogs.
- **Secure Windows Authentication** - no API keys or passwords stored in config files
- **Per-user auditing** - tracks which Windows user performed each action
- Fully modular: after setup, adding new actions is easy—just write the SQL you want to run.
- No need to create a new API for every custom action—one setup covers all your needs.

## How It Works

The API calls `usp_UserAction` **once** with four parameters:
- `@action` – the name of the action you want to perform (e.g., "UpdatePriority")
- `@internalID` – single ID or comma-separated list of IDs (e.g., "123" or "123,456,789")
- `@changeValue` – the new value or input from the user
- `@userName` – the Windows authenticated username (automatically passed, e.g., "DOMAIN\User")

### Single vs Multi-Row
- **Single row**: `@internalID` = "123"
- **Multiple rows**: `@internalID` = "123,456,789"

The stored procedure handles both cases and can perform bulk updates efficiently.

### Adding New Actions
Inside `usp_UserAction`, use the value of `@action` to branch your logic:
1. **Validation** (optional): Check if the operation is allowed using `STRING_SPLIT(@internalID, ',')`
2. **Bulk Update**: Update all rows at once using `WHERE column IN (SELECT value FROM STRING_SPLIT(@internalID, ','))`
3. **Return**: Set `@MessageCode` and `@Message` to indicate success or error

This makes it easy to add new buttons or actions in SCALE—just add a new branch in your stored procedure!

## Setup Instructions

### 1. Clone and Publish
- Clone this repository.
- Publish the project to a folder on your SCALE application server.

### 2. Install .NET 8 Hosting Bundle (if not already installed)
- Download from: https://dotnet.microsoft.com/download/dotnet/8.0
- Install the **ASP.NET Core Hosting Bundle** on your IIS server
- Run `iisreset` after installation

### 3. Edit web.config After Publishing
- Open the `web.config` file in your published folder.
- Update the connection string with your server and database name:
  ```xml
  <environmentVariable name="ConnectionStrings__DefaultConnection" 
    value="Server=YOUR_SERVER_HERE;Database=YOUR_DATABASE_HERE;Integrated Security=true;TrustServerCertificate=True;" />
  ```
- **Note**: Uses Windows Authentication (Integrated Security) - no username/password needed!

### 4. IIS Configuration
- Create a new Application Pool in IIS
  - **Important**: Use the **same service account identity** as your SCALE application pools
  - Set **.NET CLR Version** to **No Managed Code**
- Add the published folder as an Application under the same IIS site as your SCALE site
  - Suggested name: `UserAction`
- Ensure Windows Authentication is enabled:
  - In IIS Manager → Select your application → Authentication
  - Enable **Windows Authentication**
  - Disable **Anonymous Authentication**

### 5. Grant SQL Server Permissions
Run this SQL script on your SCALE database (replace `DOMAIN\ServiceAccount` with your actual service account):

```sql
USE [YourDatabase];
GO

-- Create login if it doesn't exist
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'DOMAIN\ServiceAccount')
    CREATE LOGIN [DOMAIN\ServiceAccount] FROM WINDOWS;
GO

-- Create user and grant permissions
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'DOMAIN\ServiceAccount')
    CREATE USER [DOMAIN\ServiceAccount] FOR LOGIN [DOMAIN\ServiceAccount];
GO

GRANT EXECUTE ON dbo.usp_UserAction TO [DOMAIN\ServiceAccount];
GO
```

### 6. Optional: Create Audit Table
To track who performed which actions, run `create_audit_table.sql` in your database, then uncomment the audit logging lines in `usp_UserAction`.

### 7. Recycle the App Pool
- In IIS, recycle the UserAction Application Pool to apply changes.

### 8. Integrate with Manhattan SCALE (Snapdragon)

**Important**: SCALE must pass Windows credentials when making the POST request.

#### Configuration in SCALE Dialog:
Update your dialog's save button click event:
- **Event name:** `_webUi.insightListPaneActions.modalDialogPerformPostForSelection`
- **Parameters:**
  - `POSTServiceURL=/UserAction/ExecProc?action=ExampleAction`
  - `PostData_Grid_ListPaneDataGrid_internalID=internal_num_example`
  - `PostData_Input_ExampleEditor_changeValue=value`
  - `ModalDialogName=ExampleModalDialog`
  - `UseDefaultCredentials=true` ← **Important: Passes Windows credentials**

#### Alternative: Server-Side POST from SCALE
If SCALE makes the POST request server-side (recommended), ensure the SCALE application pool identity has permissions to call the API and matches the service account configured above.

## Security Model

This API uses **Windows Authentication** for security:

✅ **No API keys or passwords** stored in configuration files  
✅ **Per-user auditing** - tracks which Windows user performed each action  
✅ **Integrated with Active Directory** - uses existing Windows authentication  
✅ **SQL Server Windows Authentication** - no database credentials needed  

The authenticated user's Windows identity (e.g., `DOMAIN\Username`) is automatically:
1. Captured by IIS/ASP.NET Core
2. Validated against Active Directory
3. Passed to the stored procedure for auditing
4. Can be logged to the optional `UserActionAudit` table

