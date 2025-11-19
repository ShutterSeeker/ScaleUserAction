// Program.cs (ASP.NET Core 8/9 Minimal API)
using Microsoft.Data.SqlClient;
using System.Data;

var builder = WebApplication.CreateBuilder(args);

// Enforce HTTPS and HSTS
builder.Services.AddHsts(options =>
{
    options.Preload = true;
    options.IncludeSubDomains = true;
    options.MaxAge = TimeSpan.FromDays(60);
});

var app = builder.Build();

app.UseHsts();
app.UseHttpsRedirection();

// Global exception handler middleware (production safe)
app.Use(async (context, next) =>
{
    try
    {
        await next();
    }
    catch (Exception ex)
    {
        // Log the error (replace with your logging framework as needed)
        app.Logger.LogError(ex, "Unhandled exception");

        context.Response.StatusCode = 500;
        context.Response.ContentType = "application/json";
        var errorJson = System.Text.Json.JsonSerializer.Serialize(new
        {
            error = "An unexpected error occurred."
        });
        await context.Response.WriteAsync(errorJson);
    }
});

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapPost("/ExecProc", async (HttpContext context, IConfiguration config) =>
{
    var req = context.Request;
    
    // Get username from SCALE's custom header (sent by SCALE web UI)
    var rawUsername = req.Headers["UserName"].FirstOrDefault() ?? "Anonymous";
    
    // Clean up username: extract just the username part
    // Handles formats: "DOMAIN\\username" -> "username", "username@domain.com" -> "username"
    var windowsIdentity = rawUsername;
    if (rawUsername.Contains('\\'))
    {
        // Extract username from DOMAIN\username
        windowsIdentity = rawUsername.Split('\\').Last();
    }
    else if (rawUsername.Contains('@'))
    {
        // Extract username from username@domain.com
        windowsIdentity = rawUsername.Split('@').First();
    }
    
    // Get 'action' from query string
    var action = req.Query["action"].ToString();
    if (string.IsNullOrWhiteSpace(action))
    {
        return Results.BadRequest(new
        {
            ErrorCode = "MissingAction",
            ErrorType = 1,
            Message = "Missing required query parameter 'action'.",
            AdditionalErrors = Array.Empty<string>(),
            Data = (object?)null
        });
    }

    // Limit request body size (e.g., 10 KB)
    if (req.ContentLength is > 10_240)
    {
        return Results.BadRequest(new
        {
            ErrorCode = "PayloadTooLarge",
            ErrorType = 1,
            Message = "Request payload too large.",
            AdditionalErrors = Array.Empty<string>(),
            Data = (object?)null
        });
    }

    using var reader = new StreamReader(req.Body);
    var raw = await reader.ReadToEndAsync();

    List<Dictionary<string, object>> items = [];
    try
    {
        items = System.Text.Json.JsonSerializer.Deserialize<List<Dictionary<string, object>>>(raw)
            ?? [];
    }
    catch
    {
        try
        {
            var obj = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, object>>(raw);
            if (obj != null)
                items.Add(obj);
        }
        catch
        {
            return Results.BadRequest(new
            {
                ErrorCode = "InvalidPayload",
                ErrorType = 1,
                Message = "Invalid payload.",
                AdditionalErrors = Array.Empty<string>(),
                Data = (object?)null
            });
        }
    }

    if (items.Count == 0)
    {
        return Results.BadRequest(new
        {
            ErrorCode = "InvalidPayload",
            ErrorType = 1,
            Message = "Invalid payload.",
            AdditionalErrors = Array.Empty<string>(),
            Data = (object?)null
        });
    }

    var connStr = config.GetConnectionString("DefaultConnection");
    if (string.IsNullOrWhiteSpace(connStr))
        return Results.Problem("Connection string not configured.", statusCode: 500);

    await using var conn = new SqlConnection(connStr);
    try
    {
        await conn.OpenAsync();
    }
    catch
    {
        return Results.Problem("Database connection failed.", statusCode: 500);
    }

    // Verify all items have required fields first
    foreach (var item in items)
    {
        if (!item.TryGetValue("internalID", out var _) || !item.TryGetValue("changeValue", out var _))
        {
            return Results.BadRequest(new Dictionary<string, object?>
            {
                ["ErrorCode"] = "MissingParams",
                ["ErrorType"] = 1,
                ["Message"] = "Missing required params 'internalID' and/or 'changeValue'.",
                ["AdditionalErrors"] = Array.Empty<string>(),
                ["Data"] = null
            });
        }
    }

    // Build comma-separated list of internal IDs (for single or multiple items)
    var internalIDs = string.Join(",", items.Select(item =>
    {
        var id = item["internalID"];
        if (id is System.Text.Json.JsonElement je && je.ValueKind == System.Text.Json.JsonValueKind.Number)
            return je.GetInt32().ToString();
        if (id is System.Text.Json.JsonElement jes && jes.ValueKind == System.Text.Json.JsonValueKind.String)
            return jes.GetString() ?? "";
        return id?.ToString() ?? "";
    }));

    // Use first item's changeValue (all rows share same value)
    var changeValueRaw = items[0]["changeValue"];
    object? changeValueObj = changeValueRaw is System.Text.Json.JsonElement jeCV && jeCV.ValueKind == System.Text.Json.JsonValueKind.Number
        ? jeCV.GetInt32()
        : changeValueRaw is System.Text.Json.JsonElement jeCVs && jeCVs.ValueKind == System.Text.Json.JsonValueKind.String
            ? jeCVs.GetString()
            : changeValueRaw;

    // Call stored procedure ONCE with comma-separated IDs and Windows username
    await using var cmd = new SqlCommand("usp_UserAction", conn) { CommandType = CommandType.StoredProcedure };
    cmd.Parameters.AddWithValue("@action", action ?? (object)DBNull.Value);
    cmd.Parameters.AddWithValue("@internalID", internalIDs);  // CSV list
    cmd.Parameters.AddWithValue("@changeValue", changeValueObj ?? DBNull.Value);
    cmd.Parameters.AddWithValue("@userName", windowsIdentity);  // Windows authenticated user

    // Collect all result messages from stored procedure and combine into single message
    var successMessages = new List<string>();
    var errorMessages = new List<string>();
    string? finalCode = null;
    
    try
    {
        await using var procReader = await cmd.ExecuteReaderAsync();
        while (await procReader.ReadAsync())
        {
            var messageCode = procReader.GetString(procReader.GetOrdinal("MessageCode"));
            var message = procReader.GetString(procReader.GetOrdinal("Message"));
            
            if (messageCode.StartsWith("ERR_", StringComparison.OrdinalIgnoreCase))
            {
                errorMessages.Add(message);
                finalCode ??= messageCode; // Use first error code
            }
            else
            {
                successMessages.Add(message);
                finalCode ??= messageCode; // Use first success code
            }
        }
        procReader.Close();
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new Dictionary<string, object?>
        {
            ["ErrorCode"] = "SqlError",
            ["ErrorType"] = 1,
            ["Message"] = ex.Message,
            ["AdditionalErrors"] = new[] { ex.ToString() },
            ["Data"] = new Dictionary<string, object?>
            {
                ["action"] = action,
                ["internalID"] = internalIDs,
                ["changeValue"] = changeValueObj
            }
        });
    }

    // If no results returned, return error
    if (finalCode == null)
    {
        return Results.BadRequest(new Dictionary<string, object?>
        {
            ["ErrorCode"] = "NoResults",
            ["ErrorType"] = 1,
            ["Message"] = "Stored procedure returned no results.",
            ["AdditionalErrors"] = Array.Empty<string>(),
            ["Data"] = null
        });
    }

    // Combine all messages into a single message
    var combinedMessage = string.Join(" ", successMessages.Concat(errorMessages));
    
    // If there are any errors, return BadRequest
    if (errorMessages.Count > 0)
    {
        return Results.BadRequest(new Dictionary<string, object?>
        {
            ["ErrorCode"] = finalCode,
            ["ErrorType"] = 1,
            ["Message"] = combinedMessage,
            ["AdditionalErrors"] = Array.Empty<string>(),
            ["Data"] = null
        });
    }

    // All success - return OK
    return Results.Ok(new Dictionary<string, object?>
    {
        ["ConfirmationMessageCode"] = null,
        ["ConfirmationMessage"] = null,
        ["MessageCode"] = finalCode,
        ["Message"] = combinedMessage
    });
});

app.Run();
