# SCALE User Action API

This API provides a generic endpoint for Manhattan SCALE, allowing user input from dialog boxes (like the "update priority" in Work Insight) to be passed alongside internal IDs to identify the record(s) to update.

## One API to Rule Them All

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
- `@userName` – the acting SCALE username from the request header (for example `bbecker`, automatically passed for auditing)

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

`usp_UserAction` is now a dispatcher procedure that routes each action to dedicated action-specific procedures.

Recommended pattern for adding a new action:
1. Create a new action procedure (for example `usp_UserAction_YourAction`)
2. Add/update dispatcher routing in `usp_UserAction`
3. Use `sql/scripts/create-user-action.sql` to create custom buttons

This keeps action logic modular and easier to deploy and maintain.

## Documentation

For deployment and SCALE wiring, use these guides:
- `DEPLOYMENT.md` for IIS/API deployment setup
- `SCALE_INTEGRATION.md` for:
  - Deploying procedures from `sql/stored-procs`
  - Running `sql/scripts/create-user-action.sql` and `sql/scripts/remove-user-action.sql`
  - Tuning script parameters for your screen/action
  - Resource key and security permission handling
  - SCALE cache clear and post-install customization workflow