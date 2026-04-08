USE [ILS]
GO
/****** Object:  StoredProcedure [dbo].[usp_UserAction]    Script Date: 4/7/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
 Mod     | Programmer    | Date       | Modification Description
 --------------------------------------------------------------------
 001     | Blake Becker  | 08/27/2025 | Created.
 002     | Blake Becker  | 10/08/2025 | Updated to accept comma-separated IDs for bulk operations.
 003     | Blake Becker  | 10/09/2025 | Updated to return multiple messages for partial success/failures.
 004     | Blake Becker  | 10/28/2025 | Added IgnoreQtyProblem.
 005     | Blake Becker  | 10/30/2025 | Added Username.
 006     | Blake Becker  | 11/18/2025 | Added ResendInboundOrder.
 007     | Blake Becker  | 12/07/2025 | Retaining received date during conversion.
 008     | Blake Becker  | 04/07/2026 | Refactored to dispatcher that routes to action-specific procedures.
*/

CREATE OR ALTER PROC [dbo].[usp_UserAction] (
    @action NVARCHAR(50)
    ,@internalID NVARCHAR(MAX)  -- Can be single ID or comma-separated list: "123" or "123,456,789"
    ,@changeValue NVARCHAR(50)
    ,@userName NVARCHAR(255) = N'SCALEAPI'
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 This stored proc is called through the UserAction API (https://github.com/ShutterSeeker/ScaleUserAction).
 Custom buttons and modals in the SCALE web app send user actions to the API, which passes parameters here.
 This design allows one API endpoint to perform any SQL action on any data through this generic procedure.
 Users select rows in SCALE, optionally enter values in a modal dialog, then the action is executed here.

 This proc now acts only as a dispatcher. Each action is implemented in
 a dedicated procedure that returns MessageCode/Message directly.
*/

SET @userName = SUBSTRING(@userName, CHARINDEX('\', @userName) + 1, LEN(@userName))
SELECT TOP 1 @userName = USER_NAME FROM USER_PROFILE WHERE USER_NAME = @userName
SET @userName = ISNULL(@userName, N'SCALEAPI')

IF @action = N'IgnoreQtyProblem'
BEGIN
    EXEC usp_UserAction_IgnoreQtyProblem
        @internalID = @internalID,
        @changeValue = @changeValue,
        @userName = @userName
    RETURN
END
ELSE IF @action = N'WavePriority'
BEGIN
    EXEC usp_UserAction_WavePriority
        @internalID = @internalID,
        @changeValue = @changeValue,
        @userName = @userName
    RETURN
END
ELSE IF @action = N'Conversion'
BEGIN
    EXEC usp_UserAction_Conversion
        @internalID = @internalID,
        @changeValue = @changeValue,
        @userName = @userName
    RETURN
END
ELSE IF @action = N'ResendInboundOrder'
BEGIN
    EXEC usp_UserAction_ResendInboundOrder
        @internalID = @internalID,
        @changeValue = @changeValue,
        @userName = @userName
    RETURN
END

SELECT
    N'ERR_UNKNOWN01' AS MessageCode,
    N'Unknown action. usp_UserAction does not recognize ' + @action AS Message
