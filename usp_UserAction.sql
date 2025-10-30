USE [ILS]
GO

/****** Object:  StoredProcedure [dbo].[usp_UserAction]    Script Date: 10/30/2025 2:03:22 PM ******/
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
*/

CREATE OR ALTER PROC [dbo].[usp_UserAction] (
    @action NVARCHAR(50)
    ,@internalID NVARCHAR(MAX)  -- Can be single ID or comma-separated list: "123" or "123,456,789"
    ,@changeValue NVARCHAR(50)
    ,@userName NVARCHAR(255) = NULL
) AS

-- Results table to collect all success/error messages
DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @MessageCode NVARCHAR(50) = N'ERR_UNKNOWN01'
DECLARE @Message NVARCHAR(500) = N'Unknown action. usp_UserAction does not recognize ' + @action

SET @userName = SUBSTRING(@userName, CHARINDEX('\', @userName) + 1, LEN(@userName)) -- Remove domain

IF @action = N'IgnoreQtyProblem'
BEGIN
    BEGIN TRY
        -- BULK UPDATE: Update all lines at once
        UPDATE SHIPMENT_DETAIL SET
            USER_DEF3 = @action
            ,DATE_TIME_STAMP = GETUTCDATE()
            ,PROCESS_STAMP = N'usp_UserAction.IgnoreQtyProblem'
            ,USER_STAMP = @userName
        WHERE INTERNAL_SHIPMENT_LINE_NUM IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ','))

        DECLARE @UpdatedCount NVARCHAR(10) = @@ROWCOUNT
        DECLARE @s NVARCHAR(10) = CASE WHEN @UpdatedCount = N'1' THEN N' ' ELSE N's ' END

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'MSG_IGNOREQTYPROBLEM01', N'Quantity problem ignored successfully! ' + @UpdatedCount + N' line' + @s + N'affected.')
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())
    END CATCH
END
ELSE IF @action = N'WavePriority'
BEGIN
    DECLARE @iPriority NUMERIC (3,0)
    SET @iPriority = CONVERT(NUMERIC (3,0), @changeValue)

    BEGIN TRY
        BEGIN TRANSACTION

        -- BULK UPDATE: Update all waves at once
        UPDATE LAUNCH_STATISTICS SET
            USER_DEF7 = @iPriority
            ,DATE_TIME_STAMP = GETUTCDATE()
            ,PROCESS_STAMP = N'usp_UserAction.WavePriority'
            ,USER_STAMP = @userName
        WHERE INTERNAL_LAUNCH_NUM IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ','))

        -- Call change priority for each wave (if required by business logic)
        DECLARE @WaveQueue TABLE (LaunchNum NUMERIC(9,0))
        DECLARE @iLaunchNum NUMERIC(9,0)
        
        -- Populate queue with all IDs
        INSERT INTO @WaveQueue (LaunchNum)
        SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ',')
        
        -- Process queue until empty
        WHILE EXISTS (SELECT 1 FROM @WaveQueue)
        BEGIN
            -- Get next record
            SELECT TOP 1 @iLaunchNum = LaunchNum FROM @WaveQueue
            
            -- Process it
            EXEC usp_ChangePriority @iLaunchNum, NULL
            
            -- Remove from queue
            DELETE FROM @WaveQueue WHERE LaunchNum = @iLaunchNum
        END

        COMMIT TRANSACTION

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'MSG_CHANGEPRIORITY01', N'Change priority successful.')
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())
    END CATCH
END
ELSE IF @action = N'Conversion'
BEGIN
    -- Global validation that applies to all records
    IF NOT EXISTS (SELECT 1 FROM ITEM WHERE @changeValue = ITEM)
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_VALIDATION02', N'The specified item does not exist. Please enter a valid item.')
        
        SELECT MessageCode, Message FROM @Results
        RETURN
    END

    -- Check if all selected items are the same
    IF EXISTS (
        SELECT 1
        FROM LOCATION_INVENTORY
        WHERE INTERNAL_LOCATION_INV IN (SELECT CONVERT(NUMERIC (9,0), value) FROM STRING_SPLIT(@internalID, ','))
        HAVING COUNT(DISTINCT ITEM) > 1
    )
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_VALIDATION01', N'Selected rows contain different items. All rows must contain the same item.')
        
        SELECT MessageCode, Message FROM @Results
        RETURN
    END

    -- Check if converting to same item
    IF @changeValue = (
        SELECT TOP 1 ITEM
        FROM LOCATION_INVENTORY
        WHERE INTERNAL_LOCATION_INV IN (SELECT CONVERT(NUMERIC (9,0), value) FROM STRING_SPLIT(@internalID, ','))
    )
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_VALIDATION03', N'The specified item must differ from the selected item.')
        
        SELECT MessageCode, Message FROM @Results
        RETURN
    END

    -- Get blacklisted locations
	DECLARE @SQL NVARCHAR(MAX) = N''
	SELECT @SQL = REPLACE(FILTER_STATEMENT, N'SELECT *', N'SELECT DISTINCT LOCATION.LOCATION')
	FROM FILTER_CONFIG_DETAIL
    WHERE RECORD_TYPE = N'LOC SEL'
        AND FILTER_NAME = N'Convert SKU blacklist'

	DECLARE @LOCS TABLE (LOCATION NVARCHAR(25))
	INSERT @LOCS
	EXECUTE SP_EXECUTESQL @SQL

    -- Process each record individually
    DECLARE @ConvQueue TABLE (InvNum NUMERIC(9,0))
    DECLARE @TotalCount INT = 0
    DECLARE @SuccessCount INT = 0
    DECLARE @iInvNum NUMERIC(9,0),
	    @dQuantity numeric(19,5),
	    @stFromContId nvarchar(50),
	    @stFromLoc nvarchar(25),
	    @stFromWhs nvarchar(25),
	    @stInventorySts nvarchar(50),
	    @stItem nvarchar(50),
	    @stItemDesc nvarchar(100),
	    @stLot nvarchar(25),
	    @FromParentLogisticsUnit nvarchar(50),
	    @ToParentLogisticsUnit nvarchar(50),
	    @stReferenceID nvarchar(25),
	    @stToContId nvarchar(50),
	    @stToLoc nvarchar(25),
	    @stToWhs nvarchar(25),
        @iError INT

    -- Populate queue with all IDs
    INSERT INTO @ConvQueue (InvNum)
    SELECT CAST(value AS INT) FROM STRING_SPLIT(@internalID, ',')
    
    SET @TotalCount = (SELECT COUNT(*) FROM @ConvQueue)
    
    -- Process queue until empty
    WHILE EXISTS (SELECT 1 FROM @ConvQueue)
    BEGIN
        -- Get next record
        SELECT TOP 1 @iInvNum = InvNum FROM @ConvQueue

        BEGIN TRY
            BEGIN TRANSACTION

            -- Per-record validation: Check quantities
            IF EXISTS (
                SELECT 1
                FROM LOCATION_INVENTORY
                WHERE INTERNAL_LOCATION_INV = @iInvNum
                AND (ALLOCATED_QTY != 0 OR SUSPENSE_QTY != 0 OR IN_TRANSIT_QTY != 0)
            )
            BEGIN
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_VALIDATION04', N'AL, IT, and SU must be zero. All quantity must be in OH.')
                
                ROLLBACK TRANSACTION
                DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
                CONTINUE
            END

            -- Per-record validation: Check blacklisted location
            IF EXISTS (
                SELECT 1
                FROM LOCATION_INVENTORY LI
                INNER JOIN @LOCS L ON L.LOCATION = LI.LOCATION
                WHERE INTERNAL_LOCATION_INV = @iInvNum
            )
            BEGIN
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_VALIDATION05', N'Location not allowed for SKU to SKU conversion.')
                
                ROLLBACK TRANSACTION
                DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
                CONTINUE
            END

            -- Collect conversion info for adjusting out
            SELECT @dQuantity = ON_HAND_QTY
                ,@stFromContId = LOGISTICS_UNIT
                ,@stFromLoc = LOCATION
                ,@stFromWhs = warehouse
                ,@stInventorySts = INVENTORY_STS
                ,@stItem = ITEM
                ,@stItemDesc = ITEM_DESC
                ,@stLot = LOT
                ,@FromParentLogisticsUnit = PARENT_LOGISTICS_UNIT
            FROM LOCATION_INVENTORY
            WHERE INTERNAL_LOCATION_INV = @iInvNum

            EXEC NNR_GetNextNumber N'InvMgmtReq', @stReferenceID OUTPUT;
            
            -- Adjust inv out
            EXEC @iError=INV_AdjustInv  N' ',N' ',N'-',N' ',NULL,N' ',N' ',N' ', N' ',NULL,
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

            -- Adjust inv in
            EXEC @iError=INV_AdjustInv  N' ',N' ',N' ',N' ',NULL,N' ',N' ',N'+',N' ',NULL,
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

            COMMIT TRANSACTION
            SET @SuccessCount = @SuccessCount + 1
            
            -- Remove from queue
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum

        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION

            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_SQLEXCEPTION02', ERROR_MESSAGE())
            
            DELETE FROM @ConvQueue WHERE InvNum = @iInvNum
        END CATCH
    END

    -- Add success message if any succeeded
    IF @SuccessCount > 0
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'MSG_CONVERSION01', CAST(@SuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalCount AS NVARCHAR(10)) + N' successfully converted.')
    END

    -- If no results were added (shouldn't happen), add unknown error
    IF NOT EXISTS (SELECT 1 FROM @Results)
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_UNKNOWN01', N'Unknown error occurred.')
    END
END

-- Return all results (grouped by unique error messages)
SELECT MessageCode, Message 
FROM @Results
GROUP BY MessageCode, Message
ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode
GO