USE [ILS]
GO
/****** Object:  StoredProcedure [dbo].[usp_UserAction_ChangeWorkstationLabel]    Script Date: 4/8/2026 12:57:43 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
 Mod     | Programmer    | Date       | Modification Description
 --------------------------------------------------------------------
 001     | Blake Becker  | 04/07/2026 | Created.
*/

ALTER     PROC [dbo].[usp_UserAction_ChangeWorkstationLabel] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Changes label related document routing records for a particular workstation
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @templatePrinter NVARCHAR(50)
DECLARE @labelPrinter NVARCHAR(50)
DECLARE @resolvedDeviceName NVARCHAR(50)
DECLARE @resolvedIsLabel BIT

SELECT TOP 1
    @resolvedDeviceName = DEVICE_NAME,
    @resolvedIsLabel = CASE WHEN PRINTER_STOCK_SYMBOL LIKE N'%LABEL%' THEN 1 ELSE 0 END
FROM PRINT_DEVICES
WHERE DEVICE_NAME = LTRIM(RTRIM(@changeValue))

SELECT @templatePrinter = LABEL_PRINTER FROM JP19_WORKSTATION_DOC_VIEW WHERE WORKSTATION = N'*Unassigned'
SELECT @labelPrinter = LABEL_PRINTER FROM JP19_WORKSTATION_DOC_VIEW WHERE WORKSTATION = @internalID

IF @resolvedDeviceName IS NULL OR @resolvedIsLabel = 0
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_CHANGEWSLABEL01', N'The selected printer is not a valid label printing device.')

    SELECT MessageCode, Message
    FROM @Results
    GROUP BY MessageCode, Message
    ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
    RETURN
END

BEGIN TRY
    BEGIN TRANSACTION

    IF (@internalID = N'*Unassigned')
    BEGIN
        UPDATE DOCUMENT_ROUTING SET
            DEVICE_NAME = @resolvedDeviceName
            ,PROCESS_STAMP = N'usp_UserAction_ChangeWorkstationLabel'
            ,DATE_TIME_STAMP = GETUTCDATE()
            ,USER_STAMP = @userName
        WHERE MACHINE_NAME IS NULL
	        AND USER_NAME IS NULL
            AND DEVICE_NAME = @templatePrinter
    END ELSE
    BEGIN
        -- Clear out any existing doc routing for this workstation / label printer
        DELETE DOCUMENT_ROUTING
        WHERE MACHINE_NAME = @internalID
            AND DEVICE_NAME = @labelPrinter

        -- Copy the "template" doc routing and insert custom values
        INSERT DOCUMENT_ROUTING (DOCUMENT_TYPE,WORK_TYPE,SHIP_TO,COMPANY,CARRIER,CARRIER_SERVICE,CONTAINER_CLASS,DOCUMENT,NUMBER_OF_COPIES,USER_DEF1,USER_DEF2,USER_DEF3,USER_DEF4,USER_DEF5,USER_DEF6,USER_DEF7,USER_DEF8,USER_NAME,WAREHOUSE,CUSTOMER,RATING_ID,COUNTRY,DEVICE_NAME,PROCESS_STAMP,DATE_TIME_STAMP,USER_STAMP,MACHINE_NAME)
        SELECT DR.DOCUMENT_TYPE,WORK_TYPE,SHIP_TO,COMPANY,CARRIER,CARRIER_SERVICE,CONTAINER_CLASS,DR.DOCUMENT,NUMBER_OF_COPIES,DR.USER_DEF1,DR.USER_DEF2,DR.USER_DEF3,DR.USER_DEF4,DR.USER_DEF5,DR.USER_DEF6,DR.USER_DEF7,DR.USER_DEF8,DR.USER_NAME,WAREHOUSE,CUSTOMER,RATING_ID,COUNTRY
            ,DEVICE_NAME = @resolvedDeviceName
            ,PROCESS_STAMP = N'usp_UserAction_ChangeWorkstationLabel'
            ,DATE_TIME_STAMP = GETUTCDATE()
            ,USER_STAMP = @userName
            ,MACHINE_NAME = @internalID
        FROM DOCUMENT_ROUTING DR
        WHERE MACHINE_NAME IS NULL
	        AND USER_NAME IS NULL
            AND DEVICE_NAME = @templatePrinter
    END

    COMMIT TRANSACTION

    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_CHANGEWSLABEL01', N'Label printer successfully changed!')

    DECLARE @msg NVARCHAR(200) = @internalID + N' label printer changed from ' + @labelPrinter + N' to ' + @resolvedDeviceName
    EXEC HIST_SaveProcHist
        N'Workstation Change',
        N'150', -- Information
        @internalID,
        NULL,
        NULL,
        NULL,
        @msg,
        N'usp_UserAction_ChangeWorkstationLabel',
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
    DECLARE @Device NVARCHAR(50) = ISNULL(@resolvedDeviceName, @changeValue)
    EXEC ADT_LogAudit
        'usp_UserAction_ChangeWorkstationLabel',
        -1,
        @Error,
        'Action: ', N'ChangeWorkstationLabel',
        'Workstation: ', @internalID,
        'Label Printer: ', @Device,
        'Error: ', @Error,
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



