// Program.cs (ASP.NET Core 8/9 Minimal API)
using Microsoft.Data.SqlClient;
using System.Data;
using System.Net;
using System.Security.Principal;

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

static string? TryGetUsernameFromUserInformationCookie(HttpRequest request)
{
    if (request.Cookies.TryGetValue("UserInformation", out var userInformationCookie))
    {
        var cookieUsername = TryParseUsernameFromCookieValue(userInformationCookie);
        if (!string.IsNullOrWhiteSpace(cookieUsername))
            return cookieUsername;
    }

    return TryGetUsernameFromCookieHeader(request.Headers.Cookie);
}

static string? TryGetUsernameFromCookieHeader(IEnumerable<string> cookieHeaders)
{
    foreach (var cookieHeader in cookieHeaders)
    {
        if (string.IsNullOrWhiteSpace(cookieHeader))
            continue;

        foreach (var cookiePart in cookieHeader.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var separatorIndex = cookiePart.IndexOf('=');
            if (separatorIndex <= 0)
                continue;

            var cookieName = cookiePart[..separatorIndex];
            if (!cookieName.Equals("UserInformation", StringComparison.OrdinalIgnoreCase))
                continue;

            var cookieValue = cookiePart[(separatorIndex + 1)..];
            var cookieUsername = TryParseUsernameFromCookieValue(cookieValue);
            if (!string.IsNullOrWhiteSpace(cookieUsername))
                return cookieUsername;
        }
    }

    return null;
}

static string? TryParseUsernameFromCookieValue(string? cookieValue)
{
    if (string.IsNullOrWhiteSpace(cookieValue))
        return null;

    var decodedCookieValue = WebUtility.UrlDecode(cookieValue);

    foreach (var part in decodedCookieValue.Split('&', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
    {
        var separatorIndex = part.IndexOf('=');
        if (separatorIndex <= 0)
            continue;

        var key = part[..separatorIndex];
        if (!key.Equals("UserName", StringComparison.OrdinalIgnoreCase))
            continue;

        var value = separatorIndex == part.Length - 1 ? string.Empty : part[(separatorIndex + 1)..];
        return string.IsNullOrWhiteSpace(value) ? null : WebUtility.UrlDecode(value);
    }

    return null;
}

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapMethods("/ExecProc", new[] { "GET", "POST" }, async (HttpContext context, IConfiguration config) =>
{
    var req = context.Request;

    // SCALE may send the acting user in a header or within the UserInformation cookie.
    var rawUsername = req.Headers["Username"].FirstOrDefault()
        ?? req.Headers["UserName"].FirstOrDefault()
        ?? TryGetUsernameFromUserInformationCookie(req)
        ?? context.User.Identity?.Name
        ?? "Anonymous";

    // Keep the short username behavior for auditing and stored procedure compatibility.
    var windowsIdentity = rawUsername.Contains('\\')
        ? rawUsername.Split('\\').Last()
        : rawUsername.Contains('@')
            ? rawUsername.Split('@').First()
            : rawUsername;
    
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

    List<Dictionary<string, object>> items = [];

    if (HttpMethods.IsGet(req.Method))
    {
        items.Add(new Dictionary<string, object>
        {
            ["internalID"] = req.Query["internalID"].ToString(),
            ["changeValue"] = req.Query["changeValue"].ToString()
        });
    }
    else
    {
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
    {
        return Results.Json(new
        {
            ErrorCode = "MissingConnectionString",
            ErrorType = 1,
            Message = "Connection string not configured.",
            AdditionalErrors = Array.Empty<string>(),
            Data = (object?)null
        }, statusCode: 500);
    }

    await using var conn = new SqlConnection(connStr);
    try
    {
        await conn.OpenAsync();
    }
    catch (Exception ex)
    {
        var csb = new SqlConnectionStringBuilder(connStr);
        var processIdentity = OperatingSystem.IsWindows()
            ? WindowsIdentity.GetCurrent()?.Name ?? "Unknown"
            : "Non-Windows";

        return Results.Json(new
        {
            ErrorCode = "DatabaseConnectionFailed",
            ErrorType = 1,
            Message = "Database connection failed.",
            AdditionalErrors = new[]
            {
                ex.Message
            },
            Data = new
            {
                RequestUser = rawUsername,
                AuditUser = windowsIdentity,
                ProcessIdentity = processIdentity,
                SqlServer = csb.DataSource,
                Database = csb.InitialCatalog,
                IntegratedSecurity = csb.IntegratedSecurity,
                SqlUser = string.IsNullOrWhiteSpace(csb.UserID) ? "<none>" : csb.UserID
            }
        }, statusCode: 500);
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

    // Preserve both standard MessageCode/Message responses and arbitrary result sets.
    var successMessages = new List<string>();
    var errorMessages = new List<string>();
    string? finalCode = null;
    Dictionary<string, object?>? firstRow = null;
    var arbitraryRows = new List<Dictionary<string, object?>>();
    var hasMessageColumns = false;
    
    try
    {
        await using var procReader = await cmd.ExecuteReaderAsync();
        var columnNames = Enumerable.Range(0, procReader.FieldCount)
            .Select(procReader.GetName)
            .ToList();

        hasMessageColumns = columnNames.Contains("MessageCode", StringComparer.OrdinalIgnoreCase)
            && columnNames.Contains("Message", StringComparer.OrdinalIgnoreCase);

        while (await procReader.ReadAsync())
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var index = 0; index < procReader.FieldCount; index++)
            {
                var value = procReader.IsDBNull(index) ? null : procReader.GetValue(index);
                row[procReader.GetName(index)] = value;
            }

            firstRow ??= row;

            if (hasMessageColumns)
            {
                var messageCode = row.TryGetValue("MessageCode", out var codeObj) ? codeObj?.ToString() ?? string.Empty : string.Empty;
                var message = row.TryGetValue("Message", out var messageObj) ? messageObj?.ToString() ?? string.Empty : string.Empty;

                if (messageCode.StartsWith("ERR_", StringComparison.OrdinalIgnoreCase))
                {
                    errorMessages.Add(message);
                    finalCode ??= messageCode;
                }
                else
                {
                    successMessages.Add(message);
                    finalCode ??= messageCode;
                }
            }
            else
            {
                arbitraryRows.Add(row);
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
    if (firstRow == null)
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

    if (!hasMessageColumns)
    {
        if (arbitraryRows.Count == 1)
            return Results.Ok(arbitraryRows[0]);

        return Results.Ok(arbitraryRows);
    }

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
    var response = new Dictionary<string, object?>
    {
        ["ConfirmationMessageCode"] = null,
        ["ConfirmationMessage"] = null,
        ["MessageCode"] = finalCode,
        ["Message"] = combinedMessage
    };

    foreach (var entry in firstRow)
    {
        if (!response.ContainsKey(entry.Key))
            response[entry.Key] = entry.Value;
    }

    return Results.Ok(response);
});

app.Run();