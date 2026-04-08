SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
 Mod     | Programmer    | Date       | Modification Description
 --------------------------------------------------------------------
 JP19     | Blake Becker  | 04/07/2026 | Created.
*/

CREATE OR ALTER PROC [dbo].[usp_UserAction_NewWorkstation] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Creates new workstation.
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @normalizedChangeValue NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@changeValue, N''))))
DECLARE @formattedChangeValue NVARCHAR(50) = N''
DECLARE @charIndex INT = 1
DECLARE @charCount INT = LEN(@normalizedChangeValue)
DECLARE @capitalizeNext BIT = 1
DECLARE @currentChar NCHAR(1)

WHILE @charIndex <= @charCount
BEGIN
    SET @currentChar = SUBSTRING(@normalizedChangeValue, @charIndex, 1)

    IF @capitalizeNext = 1 AND @currentChar LIKE N'[a-z]'
        SET @formattedChangeValue = @formattedChangeValue + UPPER(@currentChar)
    ELSE
        SET @formattedChangeValue = @formattedChangeValue + @currentChar

    SET @capitalizeNext = CASE WHEN @currentChar = N' ' THEN 1 ELSE 0 END
    SET @charIndex = @charIndex + 1
END

SET @normalizedChangeValue = @formattedChangeValue

IF EXISTS (SELECT 1 FROM JP19_WORKSTATION_DOC_VIEW WHERE WORKSTATION = @normalizedChangeValue)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_CREATEWORKSTATION01', @normalizedChangeValue + N' already exists.')

    SELECT MessageCode, Message
    FROM @Results
    GROUP BY MessageCode, Message
    ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
    RETURN
END

BEGIN TRY
    BEGIN TRANSACTION

    INSERT INTO GENERIC_CONFIG_DETAIL ([RECORD_TYPE], [IDENTIFIER], [DESCRIPTION], [SYSTEM_CREATED], [ACTIVE], [USER_DEF7], [USER_DEF8], [USER_STAMP], [PROCESS_STAMP], [DATE_TIME_STAMP]) VALUES
    (N'WORKSTATION', @normalizedChangeValue, @normalizedChangeValue, N'N', N'Y', 0.00000, 0.00000, @userName, N'usp_UserAction_NewWorkstation', GETUTCDATE())

    COMMIT TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_CREATEWORKSTATIONNT01', N'Workstation created successfully!')

    DECLARE @msg NVARCHAR(200) = N'Workstation ' + @normalizedChangeValue + N' created'
    EXEC HIST_SaveProcHist
        N'Workstation Change',
        N'150', -- Information
        @internalID,
        NULL,
        NULL,
        NULL,
        @msg,
        N'usp_UserAction_NewWorkstation',
        @userName,
        NULL,
        NULL
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())

    DECLARE @Error NVARCHAR(500) = ERROR_MESSAGE()
    EXEC ADT_LogAudit
        'usp_UserAction_NewWorkstation',
        -1,
        @Error,
        'Action: ', N'CreateWorkstation',
        'Workstation: ', @internalID,
        'Error: ', @Error,
        'User: ', @userName,
        NULL, NULL,
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



GO
