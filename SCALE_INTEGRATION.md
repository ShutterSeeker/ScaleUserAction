# SCALE Integration Guide - SCALE User Action API

This guide covers how to wire SCALE actions to the User Action API, including SQL stored procedure deployment and add/remove button automation scripts.

## Overview

SCALE integration in this project has two SQL pieces:

1. Action execution procedures in `sql/stored-procs`
2. UI automation scripts in `sql/scripts` to add/remove action buttons and wiring

The API endpoint receives calls from SCALE and routes actions to `usp_UserAction`, which dispatches to action-specific procedures.

## 1. Deploy Stored Procedures

Deploy the stored procedure files from `sql/stored-procs` to your SCALE database.

Minimum required objects:
- `sql/stored-procs/usp_UserAction.sql` (dispatcher)
- All action procedures you plan to use, such as:
  - `sql/stored-procs/usp_UserAction_WavePriority.sql`
  - `sql/stored-procs/usp_UserAction_IgnoreQtyProblem.sql`
  - etc.

Notes:
- If `usp_UserAction.sql` references an action procedure that does not exist, that action will fail when called.
- Re-run updated procedure files during deployment/upgrade to keep SQL behavior in sync with the API.

## 2. Add or Remove SCALE Buttons (Automation Scripts)

Use the scripts in `sql/scripts`:
- `sql/scripts/create-user-action.sql` to create/wire a button action
- `sql/scripts/remove-user-action.sql` to remove an existing action

Warning:
- Run `create-user-action.sql` only on screens that are already customized.
- Do not run install scripts directly against base/non-customized screens.

### Parameter Tuning (Required)

Before running either script, edit the parameter block at the top of the file for your environment and use case.

Common parameters you will tune:
- Form and action identity (`@FORM_ID`, `@ACTION`)
- Button and modal labels (`@BTN_RESOURCE_VALUE`, `@MODAL_EDITOR_RESOURCE_VALUE`)
- Grid field mappings (`@POST_INTERNAL_ID_FIELD`, and optional change-value field)
- Modal behavior (`@MODAL`, `@MODAL_DIALOG_NAME`, `@MODAL_EDITOR_NAME`)
- Selection behavior (`@ALLOW_MULTI_SELECT`, `@REQUIRE_SELECTED_ROW`)
- Security targeting (`@ALLOWED_GROUP`, `@NOT_ALLOWED_GROUP`)

## 3. What the Scripts Handle Automatically

`create-user-action.sql` is designed to do more than just add a button. It also handles:

- Resource keys and labels:
  - Creates missing resource entries
  - Reuses existing resource keys when present
- Security checkpoint and permissions:
  - Creates/updates checkpoint records
  - Updates security values for allowed/restricted groups
- SCALE UI wiring:
  - Creates action controls/events
  - Configures API post parameters
  - Supports modal and non-modal action patterns

`remove-user-action.sql` handles cleanup for:
- Action controls/events/parameters
- Modal parts/groups/controls/events (when used)
- Related security checkpoint links (when safe to remove)

## 4. Validate After Changes

After deploying procedures and running add/remove scripts:
- Confirm the button appears (or is removed) in the target SCALE form
- Trigger the action and verify `/UserAction/ExecProc?action=...` is called successfully
- Verify expected SQL updates and returned message codes/messages
- Confirm security behavior for allowed and restricted groups

## 5. Clear SCALE Cache After Changes

After UI/configuration changes (for example, after running `create-user-action.sql`), clear SCALE cache so updates appear in the UI:

- https://scale.domain.com/scale/general/clearcache

## 6. Fine-Tune Screen Elements After Install

After installing an action/button, you can fine-tune screen elements in SCALE customization:

1. Open the target insight screen.
2. Click the user icon in the top-right corner.
3. Select Customize Screen.

This opens a form details page similar to:

- https://scale.domain.com/scale/details/form/10089

In that URL, `10089` is the form ID of the screen you were on.

## Related Docs

- Deployment and IIS/API setup: `DEPLOYMENT.md`
