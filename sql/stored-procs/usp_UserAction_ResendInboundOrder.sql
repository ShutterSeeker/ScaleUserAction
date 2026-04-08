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

CREATE OR ALTER PROC [dbo].[usp_UserAction_ResendInboundOrder] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Requeues inbound order messages to TGW with new MessageId when TGW communication fails.
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @InternalInstrNum NUMERIC(9,0),
    @CurrentJSON NVARCHAR(MAX),
    @UpdatedJSON NVARCHAR(MAX),
    @MsgId NUMERIC(9,0),
    @NextNum NVARCHAR(25),
    @WorkUnit NVARCHAR(25),
    @ResendTotalCount INT = 0,
    @ResendSuccessCount INT = 0

DECLARE @ResendQueue TABLE (WorkUnit NVARCHAR(25))

INSERT INTO @ResendQueue (WorkUnit)
SELECT value FROM STRING_SPLIT(@internalID, ',')

SET @ResendTotalCount = (SELECT COUNT(*) FROM @ResendQueue)

WHILE EXISTS (SELECT 1 FROM @ResendQueue)
BEGIN
    SELECT TOP 1 @WorkUnit = WorkUnit FROM @ResendQueue

    BEGIN TRY
        SELECT @InternalInstrNum = INTERNAL_INSTRUCTION_NUM
        FROM WORK_INSTRUCTION
        WHERE WORK_UNIT = @WorkUnit
            AND INSTRUCTION_TYPE = N'Header'
            AND CONDITION IN (N'Open', N'In Process')

        IF @InternalInstrNum IS NULL
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_RESENDINBOUND01', N'Work unit ' + @WorkUnit + N' does not have a valid open header instruction.')

            EXEC ADT_LogAudit
                'usp_UserAction.ResendInboundOrder',
                -1,
                'Resend Validation Failed. Work unit does not have a valid open header instruction.',
                'WorkUnit: ', @WorkUnit,
                'Error: ', N'No open header instruction found.',
                'User: ', @userName,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                @userName,
                NULL

            DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
            SET @InternalInstrNum = NULL
            CONTINUE
        END

        SELECT TOP 1
            @CurrentJSON = D.DATA,
            @MsgId = D.MSG_ID
        FROM DIF_OUTGOING_MESSAGE D WITH (NOLOCK)
        WHERE JSON_VALUE(D.DATA, '$.InboundOrder.InboundOrderId') = CAST(@InternalInstrNum AS NVARCHAR(25))
        ORDER BY D.DATE_TIME_STAMP DESC

        IF @MsgId IS NULL OR @CurrentJSON IS NULL
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_RESENDINBOUND02', N'No outgoing DIF message found for work unit ' + @WorkUnit + N' (Instruction: ' + CAST(@InternalInstrNum AS NVARCHAR(25)) + N').')

            EXEC ADT_LogAudit
                'usp_UserAction.ResendInboundOrder',
                -1,
                'Resend Validation Failed. No outgoing DIF message found.',
                'WorkUnit: ', @WorkUnit,
                'InstrNum: ', @InternalInstrNum,
                'Error: ', N'No DIF_OUTGOING_MESSAGE found.',
                'User: ', @userName,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                @userName,
                NULL

            DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
            SET @InternalInstrNum = NULL
            SET @MsgId = NULL
            SET @CurrentJSON = NULL
            CONTINUE
        END

        EXEC NNR_GetNextNumber N'TGWInboundOrder', @NextNum OUTPUT;
        SET @NextNum = N'IB-' + RIGHT(REPLICATE(N'0', 9) + @NextNum, 9);

        SET @UpdatedJSON = JSON_MODIFY(@CurrentJSON, '$.InboundOrder.MessageId', @NextNum)
        SET @UpdatedJSON = JSON_MODIFY(@UpdatedJSON, '$.InboundOrder.MessageTimestamp', FORMAT(GETDATE(), 'yyyy-MM-ddTHH:mm:ss'))

        UPDATE DIF_OUTGOING_MESSAGE SET
            DATA = @UpdatedJSON,
            DATE_TIME_STAMP = GETUTCDATE(),
            PROCESS_STAMP = N'usp_UserAction.ResendInboundOrder',
            STATUS = N'Ready',
            USER_STAMP = @userName
        WHERE MSG_ID = @MsgId

        IF @@ROWCOUNT = 0
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_RESENDINBOUND03', N'Failed to update DIF message for work unit ' + @WorkUnit + N'.')

            EXEC ADT_LogAudit
                'usp_UserAction.ResendInboundOrder',
                -1,
                'Resend Failed. Failed to update DIF_OUTGOING_MESSAGE.',
                'WorkUnit: ', @WorkUnit,
                'InstrNum: ', @InternalInstrNum,
                'MsgId: ', @MsgId,
                'Error: ', N'UPDATE returned 0 rows affected.',
                'User: ', @userName,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                @userName,
                NULL

            DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
            SET @InternalInstrNum = NULL
            SET @MsgId = NULL
            SET @CurrentJSON = NULL
            SET @UpdatedJSON = NULL
            CONTINUE
        END

        SET @ResendSuccessCount = @ResendSuccessCount + 1

        DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit

        SET @InternalInstrNum = NULL
        SET @MsgId = NULL
        SET @CurrentJSON = NULL
        SET @UpdatedJSON = NULL

    END TRY
    BEGIN CATCH
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_RESENDINBOUND04', N'Error processing work unit ' + @WorkUnit + N': ' + ERROR_MESSAGE())

        DECLARE @ResendCatchError NVARCHAR(500) = ERROR_MESSAGE()
        EXEC ADT_LogAudit
            'usp_UserAction.ResendInboundOrder',
            -1,
            @ResendCatchError,
            'WorkUnit: ', @WorkUnit,
            'InstrNum: ', @InternalInstrNum,
            'MsgId: ', @MsgId,
            'Error: ', @ResendCatchError,
            'User: ', @userName,
            NULL, NULL,
            NULL, NULL,
            NULL, NULL,
            NULL, NULL,
            NULL, NULL,
            @userName,
            NULL

        DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit

        SET @InternalInstrNum = NULL
        SET @MsgId = NULL
        SET @CurrentJSON = NULL
        SET @UpdatedJSON = NULL
    END CATCH
END

IF @ResendSuccessCount > 0
BEGIN
    DECLARE @sResend NVARCHAR(10) = CASE WHEN @ResendSuccessCount = 1 THEN N' ' ELSE N's ' END
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_RESENDINBOUND01', CAST(@ResendSuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@ResendTotalCount AS NVARCHAR(10)) + N' inbound order' + @sResend + N'successfully queued for resend.')

    DECLARE @ResendActionCode NVARCHAR(10)
    DECLARE @ResendIdentifier1 NVARCHAR(200)
    DECLARE @ResendIdentifier2 NVARCHAR(200)
    DECLARE @ResendMessage NVARCHAR(500)

    SET @ResendActionCode = CASE WHEN @ResendSuccessCount = @ResendTotalCount THEN N'150' ELSE N'130' END
    SET @ResendIdentifier1 = N'WorkUnits: ' + @internalID
    SET @ResendIdentifier2 = N'Success: ' + CAST(@ResendSuccessCount AS NVARCHAR(10)) + N'/' + CAST(@ResendTotalCount AS NVARCHAR(10))
    SET @ResendMessage = CAST(@ResendSuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@ResendTotalCount AS NVARCHAR(10)) + N' inbound order' + @sResend + N'successfully queued for resend.'

    EXEC HIST_SaveProcHist
        N'Resend Inbound Order',
        @ResendActionCode,
        @ResendIdentifier1,
        @ResendIdentifier2,
        NULL,
        NULL,
        @ResendMessage,
        N'usp_UserAction.ResendInboundOrder',
        @userName,
        NULL,
        NULL
END

IF @ResendSuccessCount = 0 AND NOT EXISTS (SELECT 1 FROM @Results)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_RESENDINBOUND05', N'Failed to resend any inbound orders.')
END

SELECT MessageCode, Message
FROM @Results
GROUP BY MessageCode, Message
ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
