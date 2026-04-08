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

CREATE OR ALTER PROC [dbo].[usp_UserAction_Conversion] (
    @internalID NVARCHAR(MAX),
    @changeValue NVARCHAR(50),
    @userName NVARCHAR(255)
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 Converts inventory from extension item (45678-991) to base item (45678) in-place.
 Used to sell out old packaging art before selling new version under same base item.
 Preserves original received date. Validates quantities and blacklisted locations.
*/

DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

SET @changeValue = (SELECT TOP 1 ITEM FROM ITEM WHERE @changeValue = ITEM)

IF NOT EXISTS (SELECT 1 FROM ITEM WHERE @changeValue = ITEM)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_VALIDATION02', N'The specified item does not exist. Please enter a valid item.')

    SELECT MessageCode, Message FROM @Results
    RETURN
END

IF EXISTS (
    SELECT 1
    FROM LOCATION_INVENTORY
    WHERE INTERNAL_LOCATION_INV IN (SELECT CONVERT(NUMERIC(9,0), value) FROM STRING_SPLIT(@internalID, ','))
    HAVING COUNT(DISTINCT ITEM) > 1
)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_VALIDATION01', N'Selected rows contain different items. All rows must contain the same item.')

    SELECT MessageCode, Message FROM @Results
    RETURN
END

IF @changeValue = (
    SELECT TOP 1 ITEM
    FROM LOCATION_INVENTORY
    WHERE INTERNAL_LOCATION_INV IN (SELECT CONVERT(NUMERIC(9,0), value) FROM STRING_SPLIT(@internalID, ','))
)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_VALIDATION03', N'The specified item must differ from the selected item.')

    SELECT MessageCode, Message FROM @Results
    RETURN
END

DECLARE @SQL NVARCHAR(MAX) = N''
SELECT @SQL = REPLACE(FILTER_STATEMENT, N'SELECT *', N'SELECT DISTINCT LOCATION.LOCATION')
FROM FILTER_CONFIG_DETAIL
WHERE RECORD_TYPE = N'LOC SEL'
    AND FILTER_NAME = N'Convert SKU blacklist'

DECLARE @LOCS TABLE (LOCATION NVARCHAR(25))
INSERT @LOCS
EXECUTE SP_EXECUTESQL @SQL

DECLARE @ConvQueue TABLE (InvNum NUMERIC(9,0))
DECLARE @TotalCount INT = 0
DECLARE @SuccessCount INT = 0
DECLARE @iInvNum NUMERIC(9,0),
    @dQuantity NUMERIC(19,5),
    @stFromContId NVARCHAR(50),
    @stFromLoc NVARCHAR(25),
    @stFromWhs NVARCHAR(25),
    @stInventorySts NVARCHAR(50),
    @stItem NVARCHAR(50),
    @stItemDesc NVARCHAR(100),
    @stLot NVARCHAR(25),
    @FromParentLogisticsUnit NVARCHAR(50),
    @ToParentLogisticsUnit NVARCHAR(50),
    @stReferenceID NVARCHAR(25),
    @stToContId NVARCHAR(50),
    @stToLoc NVARCHAR(25),
    @stToWhs NVARCHAR(25),
    @iError INT,
    @dtReceivedDate DATETIME,
    @iNewInvNum NUMERIC(9,0)

INSERT INTO @ConvQueue (InvNum)
SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ',')

SET @TotalCount = (SELECT COUNT(*) FROM @ConvQueue)

WHILE EXISTS (SELECT 1 FROM @ConvQueue)
BEGIN
    SELECT TOP 1 @iInvNum = InvNum FROM @ConvQueue

    BEGIN TRY
        BEGIN TRANSACTION

        IF EXISTS (
            SELECT 1
            FROM LOCATION_INVENTORY
            WHERE INTERNAL_LOCATION_INV = @iInvNum
                AND (ALLOCATED_QTY != 0 OR SUSPENSE_QTY != 0 OR IN_TRANSIT_QTY != 0)
        )
        BEGIN
            DECLARE @ValItem1 NVARCHAR(50), @ValLoc1 NVARCHAR(25), @ValWhs1 NVARCHAR(25)
            SELECT @ValItem1 = ITEM, @ValLoc1 = LOCATION, @ValWhs1 = WAREHOUSE
            FROM LOCATION_INVENTORY WHERE INTERNAL_LOCATION_INV = @iInvNum

            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_VALIDATION04', N'AL, IT, and SU must be zero. All quantity must be in OH.')

            EXEC ADT_LogAudit
                'usp_UserAction.Conversion',
                -1,
                'Conversion Validation Failed. AL, IT, and SU must be zero. All quantity must be in OH.',
                'InvNum: ', @iInvNum,
                'Item: ', @ValItem1,
                'Location: ', @ValLoc1,
                'Convert to: ', @changeValue,
                'Error: ', N'AL, IT, and SU must be zero.',
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                @userName,
                @ValWhs1

            ROLLBACK TRANSACTION
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
            CONTINUE
        END

        IF EXISTS (
            SELECT 1
            FROM LOCATION_INVENTORY LI
            INNER JOIN @LOCS L ON L.LOCATION = LI.LOCATION
            WHERE INTERNAL_LOCATION_INV = @iInvNum
        )
        BEGIN
            DECLARE @ValItem2 NVARCHAR(50), @ValLoc2 NVARCHAR(25), @ValWhs2 NVARCHAR(25)
            SELECT @ValItem2 = ITEM, @ValLoc2 = LOCATION, @ValWhs2 = WAREHOUSE
            FROM LOCATION_INVENTORY WHERE INTERNAL_LOCATION_INV = @iInvNum

            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_VALIDATION05', N'Location not allowed for SKU to SKU conversion.')

            EXEC ADT_LogAudit
                'usp_UserAction.Conversion',
                -1,
                'Conversion Validation Failed. Location not allowed for SKU to SKU conversion.',
                'InvNum: ', @iInvNum,
                'Item: ', @ValItem2,
                'Location: ', @ValLoc2,
                'Convert to: ', @changeValue,
                'Error: ', N'Location blacklisted for conversion.',
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                NULL, NULL,
                @userName,
                @ValWhs2

            ROLLBACK TRANSACTION
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
            CONTINUE
        END

        SELECT @dQuantity = ON_HAND_QTY,
            @stFromContId = LOGISTICS_UNIT,
            @stFromLoc = LOCATION,
            @stFromWhs = WAREHOUSE,
            @stInventorySts = INVENTORY_STS,
            @stItem = ITEM,
            @stItemDesc = ITEM_DESC,
            @stLot = LOT,
            @FromParentLogisticsUnit = PARENT_LOGISTICS_UNIT,
            @dtReceivedDate = RECEIVED_DATE
        FROM LOCATION_INVENTORY
        WHERE INTERNAL_LOCATION_INV = @iInvNum

        EXEC NNR_GetNextNumber N'InvMgmtReq', @stReferenceID OUTPUT;

        EXEC @iError = INV_AdjustInv N' ',N' ',N'-',N' ',NULL,N' ',N' ',N' ', N' ',NULL,
            @dQuantity,0,0,NULL,NULL,NULL, N'N',@stFromContId,@stFromLoc,@stFromWhs,
            @stInventorySts,@stItem,@stItemDesc,@stLot,NULL,N'EA',NULL,@FromParentLogisticsUnit,NULL,@stReferenceID,
            N'13-SKU to SKU-0000',NULL,NULL,NULL,NULL,N'40',@changeValue,NULL,NULL,NULL,
            NULL,NULL,0,0,@userName,NULL,NULL,NULL,NULL,0,0,False;

        IF (@iError <> 0 OR @@ERROR <> 0)
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_INV_AdjustInv01', N'Failed to adjust inventory out: Error ' + CAST(@iError AS NVARCHAR(50)))

            ROLLBACK TRANSACTION
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
            CONTINUE
        END

        IF EXISTS (SELECT 1 FROM LOCATION_INVENTORY WHERE INTERNAL_LOCATION_INV = @iInvNum)
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_INV_AdjustInv02', N'Inventory failed to adjust out.')

            ROLLBACK TRANSACTION
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
            CONTINUE
        END

        SET @ToParentLogisticsUnit = @FromParentLogisticsUnit
        SET @stToContId = @stFromContId
        SET @stToLoc = @stFromLoc
        SET @stToWhs = @stFromWhs

        EXEC @iError = INV_AdjustInv N' ',N' ',N' ',N' ',NULL,N' ',N' ',N'+',N' ',NULL,
            @dQuantity,0,0,NULL,NULL,NULL,N'N',NULL,NULL,NULL,
            @stInventorySts,@changeValue,@stItemDesc,@stLot,NULL,N'EA',NULL,NULL,@FromParentLogisticsUnit,@stReferenceID,
            N'13-SKU to SKU-0000',NULL,@stToContId,@stToLoc,@stToWhs,N'40',@stItem,NULL,NULL,NULL,
            NULL,NULL,0,0,@userName,NULL,NULL,NULL,NULL,0,0,False;

        IF (@iError <> 0 OR @@ERROR <> 0)
        BEGIN
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_INV_AdjustInv03', N'Failed to adjust inventory in: Error ' + CAST(@iError AS NVARCHAR(50)))

            ROLLBACK TRANSACTION
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
            CONTINUE
        END

        SELECT TOP 1 @iNewInvNum = INTERNAL_LOCATION_INV
        FROM LOCATION_INVENTORY
        WHERE ITEM = @changeValue
            AND LOCATION = @stToLoc
            AND WAREHOUSE = @stToWhs
            AND (LOGISTICS_UNIT = @stToContId OR (LOGISTICS_UNIT IS NULL AND @stToContId IS NULL))
            AND (LOT = @stLot OR (LOT IS NULL AND @stLot IS NULL))
        ORDER BY DATE_TIME_STAMP DESC

        IF @iNewInvNum IS NOT NULL
        BEGIN
            BEGIN TRY
                UPDATE LOCATION_INVENTORY SET
                    RECEIVED_DATE = @dtReceivedDate,
                    AGING_DATE = @dtReceivedDate,
                    DATE_TIME_STAMP = GETUTCDATE(),
                    PROCESS_STAMP = N'usp_UserAction.Conversion',
                    USER_STAMP = @userName
                WHERE INTERNAL_LOCATION_INV = @iNewInvNum
            END TRY
            BEGIN CATCH
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_RECEIVEDDATE01', N'Conversion succeeded but failed to update received date: ' + ERROR_MESSAGE())
            END CATCH
        END

        COMMIT TRANSACTION
        SET @SuccessCount = @SuccessCount + 1

        DELETE FROM @ConvQueue WHERE InvNum = @iInvNum

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        DECLARE @CatchItem NVARCHAR(50) = NULL, @CatchLoc NVARCHAR(25) = NULL, @CatchWhs NVARCHAR(25) = NULL
        SELECT @CatchItem = ITEM, @CatchLoc = LOCATION, @CatchWhs = WAREHOUSE
        FROM LOCATION_INVENTORY WHERE INTERNAL_LOCATION_INV = @iInvNum

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_SQLEXCEPTION02', ERROR_MESSAGE())

        DECLARE @ConvCatchError NVARCHAR(500) = ERROR_MESSAGE()
        EXEC ADT_LogAudit
            'usp_UserAction.Conversion',
            -1,
            @ConvCatchError,
            'InvNum: ', @iInvNum,
            'Item: ', @CatchItem,
            'Location: ', @CatchLoc,
            'Convert to: ', @changeValue,
            'Error: ', @ConvCatchError,
            'User: ', @userName,
            NULL, NULL,
            NULL, NULL,
            NULL, NULL,
            NULL, NULL,
            @userName,
            @CatchWhs

        DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
    END CATCH
END

IF @SuccessCount > 0
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'MSG_CONVERSION01', CAST(@SuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalCount AS NVARCHAR(10)) + N' successfully converted.')

    DECLARE @ConvActionCode NVARCHAR(10)
    DECLARE @ConvIdentifier1 NVARCHAR(200)
    DECLARE @ConvIdentifier2 NVARCHAR(200)
    DECLARE @ConvMessage NVARCHAR(500)

    SET @ConvActionCode = CASE WHEN @SuccessCount = @TotalCount THEN N'150' ELSE N'130' END
    SET @ConvIdentifier1 = N'Convert to: ' + @changeValue
    SET @ConvIdentifier2 = N'Success: ' + CAST(@SuccessCount AS NVARCHAR(10)) + N'/' + CAST(@TotalCount AS NVARCHAR(10))
    SET @ConvMessage = CAST(@SuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalCount AS NVARCHAR(10)) + N' successfully converted to ' + @changeValue + N'.'

    EXEC HIST_SaveProcHist
        N'SKU to SKU Conversion',
        @ConvActionCode,
        @ConvIdentifier1,
        @ConvIdentifier2,
        NULL,
        NULL,
        @ConvMessage,
        N'usp_UserAction.Conversion',
        @userName,
        NULL,
        NULL
END

IF NOT EXISTS (SELECT 1 FROM @Results)
BEGIN
    INSERT INTO @Results (MessageCode, Message)
    VALUES (N'ERR_UNKNOWN01', N'Unknown error occurred.')
END

SELECT MessageCode, Message
FROM @Results
GROUP BY MessageCode, Message
ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
