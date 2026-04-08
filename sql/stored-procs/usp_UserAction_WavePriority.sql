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

CREATE OR ALTER PROC [dbo].[usp_UserAction_WavePriority] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Changes wave replenishment priority to control which orders get prepared first
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @iPriority NUMERIC(3,0)
SET @iPriority = CONVERT(NUMERIC(3,0), @changeValue)

BEGIN TRY
    BEGIN TRANSACTION

    UPDATE LAUNCH_STATISTICS SET
        USER_DEF7 = @iPriority,
        DATE_TIME_STAMP = GETUTCDATE(),
        PROCESS_STAMP = N'usp_UserAction.WavePriority',
        USER_STAMP = @userName
    WHERE INTERNAL_LAUNCH_NUM IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ','))

    DECLARE @WaveQueue TABLE (LaunchNum NUMERIC(9,0))
    DECLARE @iLaunchNum NUMERIC(9,0)

    INSERT INTO @WaveQueue (LaunchNum)
    SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ',')

    WHILE EXISTS (SELECT 1 FROM @WaveQueue)
    BEGIN
        SELECT TOP 1 @iLaunchNum = LaunchNum FROM @WaveQueue
        EXEC usp_ChangePriority @iLaunchNum, NULL
        DELETE FROM @WaveQueue WHERE LaunchNum = @iLaunchNum
    END

    COMMIT TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_CHANGEPRIORITY01', N'Change priority successful.')

    DECLARE @PriorityIdentifier NVARCHAR(200) = N'Priority: ' + CAST(@iPriority AS NVARCHAR(10))
    EXEC HIST_SaveProcHist
        N'Wave Priority Change',
        N'150',
        @internalID,
        @PriorityIdentifier,
        NULL,
        NULL,
        N'Change priority successful.',
        N'usp_UserAction.WavePriority',
        @userName,
        NULL,
        NULL
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())

    DECLARE @WavePriorityError NVARCHAR(500) = ERROR_MESSAGE()
    DECLARE @WavePriorityStr NVARCHAR(50) = CAST(@iPriority AS NVARCHAR(10))
    EXEC ADT_LogAudit
        'usp_UserAction.WavePriority',
        -1,
        @WavePriorityError,
        'Action: ', N'WavePriority',
        'LaunchNums: ', @internalID,
        'Priority: ', @WavePriorityStr,
        'Error: ', @WavePriorityError,
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
