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
 006     | Blake Becker  | 11/18/2025 | Added ResendInboundOrder.
 007     | Blake Becker  | 12/07/2025 | Retaining received date during conversion.
*/

CREATE OR ALTER PROC [dbo].[usp_UserAction] (
    @action NVARCHAR(50)
    ,@internalID NVARCHAR(MAX)  -- Can be single ID or comma-separated list: "123" or "123,456,789"
    ,@changeValue NVARCHAR(50)
    ,@userName NVARCHAR(255) = N'ILSSRV'
) AS

/*
 Stored procedure explanation
 --------------------------------------------------------------------
 This stored proc is called through the UserAction API (https://github.com/ShutterSeeker/ScaleUserAction).
 Custom buttons and modals in the SCALE web app send user actions to the API, which passes parameters here.
 This design allows one API endpoint to perform any SQL action on any data through this generic procedure.
 Users select rows in SCALE, optionally enter values in a modal dialog, then the action is executed here.

 Action summary
 --------------------------------------------------------------------
 IgnoreQtyProblem:   Flags shipment details to allow waves with non-standard quantities to run
 WavePriority:       Changes wave replenishment priority to control which orders get prepared first
 Conversion:         Converts inventory from extension item (45678-991) to base item (45678) in-place.
                     Used to sell out old packaging art before selling new version under same base item.
                     Preserves original received date. Validates quantities and blacklisted locations.
 ResendInboundOrder: Requeues inbound order messages to TGW with new MessageId when TGW communication fails
*/

-- Results table to collect all success/error messages
DECLARE @Results TABLE(
    MessageCode NVARCHAR(50),
    Message NVARCHAR(500)
)

DECLARE @MessageCode NVARCHAR(50) = N'ERR_UNKNOWN01'
DECLARE @Message NVARCHAR(500) = N'Unknown action. usp_UserAction does not recognize ' + @action

SET @userName = SUBSTRING(@userName, CHARINDEX('\', @userName) + 1, LEN(@userName)) -- Remove domain
SELECT TOP 1 @userName = USER_NAME FROM USER_PROFILE WHERE USER_NAME = @userName -- normalize casing and verify this is a SCALE user

SET @userName = ISNULL(@userName, N'ILSSRV') -- Default to ILSSRV if username is null

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

        -- Log success
        DECLARE @IgnoreQtyMsg NVARCHAR(500) = N'Quantity problem ignored successfully! ' + @UpdatedCount + N' line' + @s + N'affected.'
        EXEC HIST_SaveProcHist 
            N'Ignore Qty Problem',                              -- @stProcess
            N'150',                                             -- @stAction (150 = Information)
            @internalID,                                        -- @stIdentifier1
            NULL,                                               -- @stIdentifier2
            NULL,                                               -- @stIdentifier3
            NULL,                                               -- @stIdentifier4
            @IgnoreQtyMsg,                                      -- @stMessage
            N'usp_UserAction.IgnoreQtyProblem',                 -- @stProcessStamp
            @userName,                                          -- @stUserName
            NULL,                                               -- @stWarehouse
            NULL                                                -- @cProcHistActive
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())

        -- Log SQL failure
        DECLARE @IgnoreQtyError NVARCHAR(500) = ERROR_MESSAGE()
        EXEC ADT_LogAudit 
            'usp_UserAction.IgnoreQtyProblem',                  -- procName
            -1,                                                 -- returnValue
            @IgnoreQtyError,                                    -- message
            'Action: ', @action,                                -- parm1
            'InternalIDs: ', @internalID,                       -- parm2
            'Error: ', @IgnoreQtyError,                         -- parm3
            'User: ', @userName,                                -- parm4
            NULL, NULL,                                         -- parm5
            NULL, NULL,                                         -- parm6
            NULL, NULL,                                         -- parm7
            NULL, NULL,                                         -- parm8
            NULL, NULL,                                         -- parm9
            NULL, NULL,                                         -- parm10
            @userName,                                          -- userName
            NULL                                                -- warehouse
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

        -- Log success
        DECLARE @PriorityIdentifier NVARCHAR(200) = N'Priority: ' + CAST(@iPriority AS NVARCHAR(10))
        EXEC HIST_SaveProcHist 
            N'Wave Priority Change',                            -- @stProcess
            N'150',                                             -- @stAction (150 = Information)
            @internalID,                                        -- @stIdentifier1
            @PriorityIdentifier,                                -- @stIdentifier2
            NULL,                                               -- @stIdentifier3
            NULL,                                               -- @stIdentifier4
            N'Change priority successful.',                     -- @stMessage
            N'usp_UserAction.WavePriority',                     -- @stProcessStamp
            @userName,                                          -- @stUserName
            NULL,                                               -- @stWarehouse
            NULL                                                -- @cProcHistActive
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_SQLEXCEPTION01', ERROR_MESSAGE())

        -- Log SQL failure
        DECLARE @WavePriorityError NVARCHAR(500) = ERROR_MESSAGE()
        DECLARE @WavePriorityStr NVARCHAR(50) = CAST(@iPriority AS NVARCHAR(10))
        EXEC ADT_LogAudit 
            'usp_UserAction.WavePriority',                      -- procName
            -1,                                                 -- returnValue
            @WavePriorityError,                                 -- message
            'Action: ', @action,                                -- parm1
            'LaunchNums: ', @internalID,                        -- parm2
            'Priority: ', @WavePriorityStr,                     -- parm3
            'Error: ', @WavePriorityError,                      -- parm4
            'User: ', @userName,                                -- parm5
            NULL, NULL,                                         -- parm6
            NULL, NULL,                                         -- parm7
            NULL, NULL,                                         -- parm8
            NULL, NULL,                                         -- parm9
            NULL, NULL,                                         -- parm10
            @userName,                                          -- userName
            NULL                                                -- warehouse
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
        @iError INT,
        @dtReceivedDate DATETIME,
        @iNewInvNum NUMERIC(9,0)

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
                DECLARE @ValItem1 NVARCHAR(50), @ValLoc1 NVARCHAR(25), @ValWhs1 NVARCHAR(25)
                SELECT @ValItem1 = ITEM, @ValLoc1 = LOCATION, @ValWhs1 = WAREHOUSE
                FROM LOCATION_INVENTORY WHERE INTERNAL_LOCATION_INV = @iInvNum

                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_VALIDATION04', N'AL, IT, and SU must be zero. All quantity must be in OH.')
                
                -- Log validation failure
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

            -- Per-record validation: Check blacklisted location
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
                
                -- Log validation failure
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
                ,@dtReceivedDate = RECEIVED_DATE
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

            -- Find the newly created inventory record to update RECEIVED_DATE
            SELECT TOP 1 @iNewInvNum = INTERNAL_LOCATION_INV
            FROM LOCATION_INVENTORY
            WHERE ITEM = @changeValue
                AND LOCATION = @stToLoc
                AND WAREHOUSE = @stToWhs
                AND (LOGISTICS_UNIT = @stToContId OR (LOGISTICS_UNIT IS NULL AND @stToContId IS NULL))
                AND (LOT = @stLot OR (LOT IS NULL AND @stLot IS NULL))
            ORDER BY DATE_TIME_STAMP DESC

            -- Update RECEIVED_DATE on new inventory (non-blocking - log error but don't rollback)
            IF @iNewInvNum IS NOT NULL
            BEGIN
                BEGIN TRY
                    UPDATE LOCATION_INVENTORY SET
                        RECEIVED_DATE = @dtReceivedDate
                        ,DATE_TIME_STAMP = GETUTCDATE()
                        ,PROCESS_STAMP = N'usp_UserAction.Conversion'
                        ,USER_STAMP = @userName
                    WHERE INTERNAL_LOCATION_INV = @iNewInvNum
                END TRY
                BEGIN CATCH
                    -- Log error but continue - don't rollback the conversion
                    INSERT INTO @Results (MessageCode, Message)
                    VALUES (N'ERR_RECEIVEDDATE01', N'Conversion succeeded but failed to update received date: ' + ERROR_MESSAGE())
                END CATCH
            END

            COMMIT TRANSACTION
            SET @SuccessCount = @SuccessCount + 1
            
            -- Remove from queue
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
            
            -- Log SQL exception
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

    -- Add success message if any succeeded
    IF @SuccessCount > 0
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'MSG_CONVERSION01', CAST(@SuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalCount AS NVARCHAR(10)) + N' successfully converted.')

        -- Log success summary
        DECLARE @ConvActionCode NVARCHAR(10)
        DECLARE @ConvIdentifier1 NVARCHAR(200)
        DECLARE @ConvIdentifier2 NVARCHAR(200)
        DECLARE @ConvMessage NVARCHAR(500)
        
        SET @ConvActionCode = CASE WHEN @SuccessCount = @TotalCount THEN N'150' ELSE N'130' END
        SET @ConvIdentifier1 = N'Convert to: ' + @changeValue
        SET @ConvIdentifier2 = N'Success: ' + CAST(@SuccessCount AS NVARCHAR(10)) + N'/' + CAST(@TotalCount AS NVARCHAR(10))
        SET @ConvMessage = CAST(@SuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalCount AS NVARCHAR(10)) + N' successfully converted to ' + @changeValue + N'.'
        
        EXEC HIST_SaveProcHist 
            N'SKU to SKU Conversion',                           -- @stProcess
            @ConvActionCode,                                    -- @stAction (150 = Information, 130 = Execution Error)
            @ConvIdentifier1,                                   -- @stIdentifier1
            @ConvIdentifier2,                                   -- @stIdentifier2
            NULL,                                               -- @stIdentifier3
            NULL,                                               -- @stIdentifier4
            @ConvMessage,                                       -- @stMessage
            N'usp_UserAction.Conversion',                       -- @stProcessStamp
            @userName,                                          -- @stUserName
            NULL,                                               -- @stWarehouse
            NULL                                                -- @cProcHistActive
    END

    -- If no results were added (shouldn't happen), add unknown error
    IF NOT EXISTS (SELECT 1 FROM @Results)
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_UNKNOWN01', N'Unknown error occurred.')
    END
END
ELSE IF @action = N'ResendInboundOrder'
BEGIN
    DECLARE @InternalInstrNum NUMERIC (9,0)
        ,@CurrentJSON NVARCHAR(MAX)
        ,@UpdatedJSON NVARCHAR(MAX)
        ,@MsgId NUMERIC (9,0)
        ,@NextNum NVARCHAR(25)
        ,@WorkUnit NVARCHAR(25)
        ,@ResendTotalCount INT = 0
        ,@ResendSuccessCount INT = 0

    -- Process each work unit individually
    DECLARE @ResendQueue TABLE (WorkUnit NVARCHAR(25))
    
    -- Populate queue with all IDs
    INSERT INTO @ResendQueue (WorkUnit)
    SELECT value FROM STRING_SPLIT(@internalID, ',')
    
    SET @ResendTotalCount = (SELECT COUNT(*) FROM @ResendQueue)
    
    -- Process queue until empty
    WHILE EXISTS (SELECT 1 FROM @ResendQueue)
    BEGIN
        -- Get next record
        SELECT TOP 1 @WorkUnit = WorkUnit FROM @ResendQueue
        
        BEGIN TRY
            -- Get the header internal instruction number from the work unit
            SELECT @InternalInstrNum = INTERNAL_INSTRUCTION_NUM 
            FROM WORK_INSTRUCTION 
            WHERE WORK_UNIT = @WorkUnit
                AND INSTRUCTION_TYPE = N'Header'
                AND CONDITION = N'Open'

            -- Validate we found an instruction number
            IF @InternalInstrNum IS NULL
            BEGIN
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_RESENDINBOUND01', N'Work unit ' + @WorkUnit + N' does not have a valid open header instruction.')
                
                -- Log validation failure
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
                    NULL, NULL,
                    @userName,
                    NULL

                DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
                SET @InternalInstrNum = NULL
                CONTINUE
            END

            -- Find the already sent outgoing DIF message for this work unit
            SELECT TOP 1
                @CurrentJSON = D.DATA
                ,@MsgId = D.MSG_ID
            FROM DIF_OUTGOING_MESSAGE D WITH (NOLOCK)
            WHERE JSON_VALUE(D.DATA, '$.InboundOrder.InboundOrderId') = CAST(@InternalInstrNum AS NVARCHAR(25)) -- Match by InboundOrderId in JSON
            ORDER BY D.DATE_TIME_STAMP DESC

            -- Validate we found a DIF message
            IF @MsgId IS NULL OR @CurrentJSON IS NULL
            BEGIN
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_RESENDINBOUND02', N'No outgoing DIF message found for work unit ' + @WorkUnit + N' (Instruction: ' + CAST(@InternalInstrNum AS NVARCHAR(25)) + N').')
                
                -- Log validation failure
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
                    NULL, NULL,
                    @userName,
                    NULL

                DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
                SET @InternalInstrNum = NULL
                SET @MsgId = NULL
                SET @CurrentJSON = NULL
                CONTINUE
            END

            -- Get NextNum
            EXEC NNR_GetNextNumber N'TGWInboundOrder', @NextNum OUTPUT;
            SET @NextNum = N'IB-' + RIGHT(REPLICATE(N'0', 9) + @NextNum, 9);

            -- Prepare updated JSON with new MessageId and MessageTimestamp
            -- This will update only those two fields while preserving all other JSON properties
            SET @UpdatedJSON = JSON_MODIFY(@CurrentJSON, '$.InboundOrder.MessageId', @NextNum)
            SET @UpdatedJSON = JSON_MODIFY(@UpdatedJSON, '$.InboundOrder.MessageTimestamp', FORMAT(GETDATE(), 'yyyy-MM-ddTHH:mm:ss'))

            -- Update the DIF_OUTGOING_MESSAGE
            UPDATE DIF_OUTGOING_MESSAGE SET 
                DATA = @UpdatedJSON
                ,DATE_TIME_STAMP = GETUTCDATE()
                ,PROCESS_STAMP = N'usp_UserAction.ResendInboundOrder'
                ,STATUS = N'Ready'
                ,USER_STAMP = @userName
            WHERE MSG_ID = @MsgId

            -- Verify update succeeded
            IF @@ROWCOUNT = 0
            BEGIN
                INSERT INTO @Results (MessageCode, Message)
                VALUES (N'ERR_RESENDINBOUND03', N'Failed to update DIF message for work unit ' + @WorkUnit + N'.')
                
                -- Log update failure
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
            
            -- Remove from queue
            DELETE FROM @ResendQueue WHERE WorkUnit = @WorkUnit
            
            -- Reset variables for next iteration
            SET @InternalInstrNum = NULL
            SET @MsgId = NULL
            SET @CurrentJSON = NULL
            SET @UpdatedJSON = NULL

        END TRY
        BEGIN CATCH
            INSERT INTO @Results (MessageCode, Message)
            VALUES (N'ERR_RESENDINBOUND04', N'Error processing work unit ' + @WorkUnit + N': ' + ERROR_MESSAGE())
            
            -- Log SQL exception
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
            
            -- Reset variables for next iteration
            SET @InternalInstrNum = NULL
            SET @MsgId = NULL
            SET @CurrentJSON = NULL
            SET @UpdatedJSON = NULL
        END CATCH
    END

    -- Add success message if any succeeded
    IF @ResendSuccessCount > 0
    BEGIN
        DECLARE @sResend NVARCHAR(10) = CASE WHEN @ResendSuccessCount = 1 THEN N' ' ELSE N's ' END
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'MSG_RESENDINBOUND01', CAST(@ResendSuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@ResendTotalCount AS NVARCHAR(10)) + N' inbound order' + @sResend + N'successfully queued for resend.')

        -- Log success summary
        DECLARE @ResendActionCode NVARCHAR(10)
        DECLARE @ResendIdentifier1 NVARCHAR(200)
        DECLARE @ResendIdentifier2 NVARCHAR(200)
        DECLARE @ResendMessage NVARCHAR(500)
        
        SET @ResendActionCode = CASE WHEN @ResendSuccessCount = @ResendTotalCount THEN N'150' ELSE N'130' END
        SET @ResendIdentifier1 = N'WorkUnits: ' + @internalID
        SET @ResendIdentifier2 = N'Success: ' + CAST(@ResendSuccessCount AS NVARCHAR(10)) + N'/' + CAST(@ResendTotalCount AS NVARCHAR(10))
        SET @ResendMessage = CAST(@ResendSuccessCount AS NVARCHAR(10)) + N' of ' + CAST(@ResendTotalCount AS NVARCHAR(10)) + N' inbound order' + @sResend + N'successfully queued for resend.'
        
        EXEC HIST_SaveProcHist 
            N'Resend Inbound Order',                            -- @stProcess
            @ResendActionCode,                                  -- @stAction (150 = Information, 130 = Execution Error)
            @ResendIdentifier1,                                 -- @stIdentifier1
            @ResendIdentifier2,                                 -- @stIdentifier2
            NULL,                                               -- @stIdentifier3
            NULL,                                               -- @stIdentifier4
            @ResendMessage,                                     -- @stMessage
            N'usp_UserAction.ResendInboundOrder',               -- @stProcessStamp
            @userName,                                          -- @stUserName
            NULL,                                               -- @stWarehouse
            NULL                                                -- @cProcHistActive
    END

    -- If none succeeded and no specific errors were added, add unknown error
    IF @ResendSuccessCount = 0 AND NOT EXISTS (SELECT 1 FROM @Results)
    BEGIN
        INSERT INTO @Results (MessageCode, Message)
        VALUES (N'ERR_RESENDINBOUND05', N'Failed to resend any inbound orders.')
    END
END

-- Return all results (grouped by unique error messages)
SELECT MessageCode, Message 
FROM @Results
GROUP BY MessageCode, Message
ORDER BY CASE WHEN MessageCode LIKE 'MSG_%' THEN 1 ELSE 2 END, MessageCode

GO
