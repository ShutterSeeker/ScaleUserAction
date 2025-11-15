# SCALE User Action API

This API provides a generic endpoint for Manhattan SCALE, allowing user input from dialog boxes (like the "update priority" in Work Insight) to be passed alongside internal IDs to identify the record(s) to update.

## Why This API is Awesome

This project lets you easily add custom actions to your Manhattan SCALE web app. With this tool, you can:
- **Edit any table in SCALE** using simple user input from a dialog box—only SQL coding required for each new action!
- **Works directly with your existing SCALE web app and dialogs**
- **Per-user auditing** - tracks which user performed each action
- **Fully modular**: after setup, adding new actions is easy—just write the SQL you want to run
- **No need to create a new API for every custom action**—one setup covers all your needs

## How It Works

The API calls `usp_UserAction` **once** with four parameters:
- `@action` – the name of the action you want to perform (e.g., "UpdatePriority")
- `@internalID` – single ID or comma-separated list of IDs (e.g., "123" or "123,456,789")
- `@changeValue` – the new value or input from the user
- `@userName` – the Windows authenticated username (automatically passed, e.g., "DOMAIN\User")

### Single vs Multi-Row Operations

- **Single row**: `@internalID` = "123"
- **Multiple rows**: `@internalID` = "123,456,789"

The stored procedure handles both cases and can perform bulk updates efficiently.

### Flexible Error Handling

You control how errors are handled based on your business logic:

- **Fail the whole batch**: If any row fails validation, reject the entire operation
- **Process valid rows**: Skip invalid rows and process only the valid ones
- **Partial success**: Return detailed messages about which rows succeeded/failed

### Adding New Actions

Inside `usp_UserAction`, use the value of `@action` to branch your logic:
1. **Validation** (optional): Check if the operation is allowed using `STRING_SPLIT(@internalID, ',')`
2. **Bulk Update**: Update all rows at once using `WHERE column IN (SELECT value FROM STRING_SPLIT(@internalID, ','))`
3. **Return**: Set `@MessageCode` and `@Message` to indicate success or error

This makes it easy to add new buttons or actions in SCALE—just add a new branch in your stored procedure!

#### Configuration in SCALE Dialog (snapdragon):
Update your dialog's save button click event:
- **Event name:** `_webUi.insightListPaneActions.modalDialogPerformPostForSelection`
- **Parameters:**
  - `POSTServiceURL=/UserAction/ExecProc?action=ExampleAction`
  - `PostData_Grid_ListPaneDataGrid_internalID=internal_num_example`
  - `PostData_Input_ExampleEditor_changeValue=value`
  - `ModalDialogName=ExampleModalDialog`