USE [ILS]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
 Mod     | Programmer    | Date       | Modification Description
 --------------------------------------------------------------------
 001     | Blake Becker  | 04/07/2026 | Split from usp_UserAction.
*/

CREATE OR ALTER PROC [dbo].[usp_UserAction_IgnoreQtyProblem] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Flags shipment details to allow waves with non-standard quantities to run.
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

BEGIN TRY
    UPDATE SHIPMENT_DETAIL SET
        USER_DEF3 = N'IgnoreQtyProblem',
        DATE_TIME_STAMP = GETUTCDATE(),
        PROCESS_STAMP = N'usp_UserAction.IgnoreQtyProblem',
        USER_STAMP = @userName
    WHERE INTERNAL_SHIPMENT_LINE_NUM IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ','))

    DECLARE @UpdatedCount NVARCHAR(10) = @@ROWCOUNT
    DECLARE @s NVARCHAR(10) = CASE WHEN @UpdatedCount = N'1' THEN N' ' ELSE N's ' END

    DECLARE @IgnoreQtyMsg NVARCHAR(500) = N'Quantity problem ignored successfully! ' + @UpdatedCount + N' line' + @s + N'affected.'

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_IGNOREQTYPROBLEM01', @IgnoreQtyMsg)

    EXEC HIST_SaveProcHist
        N'Ignore Qty Problem',
        N'150',
        @internalID,
        NULL,
        NULL,
        NULL,
        @IgnoreQtyMsg,
        N'usp_UserAction.IgnoreQtyProblem',
        @userName,
        NULL,
        NULL
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())

    DECLARE @IgnoreQtyError NVARCHAR(500) = ERROR_MESSAGE()
    EXEC ADT_LogAudit
        'usp_UserAction.IgnoreQtyProblem',
        -1,
        @IgnoreQtyError,
        'Action: ', N'IgnoreQtyProblem',
        'InternalIDs: ', @internalID,
        'Error: ', @IgnoreQtyError,
        'User: ', @userName,
        NULL, NULL,
        NULL, NULL,
        NULL, NULL,
        NULL, NULL,
        NULL, NULL,
        @userName,
        NULL
END CATCH

SELECT MessageCode, Message
FROM @Results
GROUP BY MessageCode, Message
ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
