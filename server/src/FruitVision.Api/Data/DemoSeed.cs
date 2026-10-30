using System.Text.Json;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public static class DemoSeed
{
    private const string SeedId = "fruitvision-demo-seed-v1";

    public static async Task Run(IServiceProvider services, IConfiguration configuration, IHostEnvironment environment)
    {
        if (!configuration.GetValue<bool>("Demo:Enabled")) return;
        if (environment.IsProduction())
            throw new InvalidOperationException("Demo seeding must not be enabled in Production.");
        var password = configuration["Demo:Password"];
        if (string.IsNullOrWhiteSpace(password) || password.Length < 16)
            throw new InvalidOperationException("Demo:Password must be privately configured with at least 16 characters.");

        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(
            Path.Combine(AppContext.BaseDirectory, "seed", "demo-data.json")));
        var root = document.RootElement;
        if (Text(root, "schema") != SeedId || !root.GetProperty("isDemo").GetBoolean())
            throw new InvalidOperationException("The demo fixture schema or demo marker is invalid.");
        var users = Rows(root, "users");
        var products = Rows(root, "products");
        var posts = Rows(root, "posts");
        var conversations = Rows(root, "conversations");
        var history = Rows(root, "history");
        if (users.Length != 24 || products.Length != 3 || posts.Length != 60 || conversations.Length != 16 ||
            history.Length != 200 || conversations.Any(c => Rows(c, "messages").Length != 30))
            throw new InvalidOperationException("The demo fixture is incomplete.");

        await using var scope = services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var manager = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
        await using var transaction = await db.Database.BeginTransactionAsync();
        // Serialize seed attempts across application instances until this transaction ends.
        await db.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(717350460127)");
        if (await db.SeedRuns.AnyAsync(s => s.Id == SeedId)) return;

        var normalizedEmails = users.Select(u => manager.NormalizeEmail(Text(u, "email"))).ToArray();
        var productCodes = products.Select(p => Text(p, "code")).ToArray();
        var postIds = posts.Select(p => Id(p)).ToArray();
        var conversationIds = conversations.Select(c => Id(c)).ToArray();
        var messageIds = conversations.SelectMany(c => Rows(c, "messages")).Select(m => Id(m)).ToArray();
        var historyIds = history.Select(h => Id(h)).ToArray();
        if (await db.Users.AnyAsync(u => normalizedEmails.Contains(u.NormalizedEmail)) ||
            await db.Products.AnyAsync(p => productCodes.Contains(p.Code)) ||
            await db.Posts.AnyAsync(p => postIds.Contains(p.Id)) ||
            await db.Conversations.AnyAsync(c => conversationIds.Contains(c.Id)) ||
            await db.Messages.AnyAsync(m => messageIds.Contains(m.Id)) ||
            await db.InteractionHistories.AnyAsync(h => historyIds.Contains(h.Id)))
            throw new InvalidOperationException("Demo fixture records already exist without a completed seed marker; no records were changed.");

        var byEmail = new Dictionary<string, Guid>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in users)
        {
            var email = Text(row, "email");
            var user = new AppUser {
                Id = Guid.NewGuid(), Email = email, UserName = email,
                DisplayName = Text(row, "displayName"), Region = Text(row, "region"),
                Role = Enum.Parse<AccountRole>(Text(row, "role")),
                ApprovalStatus = Enum.Parse<ApprovalState>(Text(row, "approvalStatus")),
                LockoutEnabled = true, EmailConfirmed = true
            };
            var result = await manager.CreateAsync(user, password);
            if (!result.Succeeded)
                throw new InvalidOperationException("Demo user creation failed; the seed transaction will be rolled back.");
            byEmail.Add(email, user.Id);
        }
        foreach (var row in products)
            db.Products.Add(new Product { Code = Text(row, "code"), Name = Text(row, "name"), Unit = Text(row, "unit") });
        foreach (var row in posts)
            db.Posts.Add(new Post {
                Id = Id(row), AuthorId = byEmail[Text(row, "authorEmail")],
                Title = Text(row, "title"), Body = Text(row, "body"), ProductCode = Text(row, "productCode"),
                Status = Text(row, "status"), SourceType = Text(row, "sourceType"),
                EstimatedQuantityKg = row.GetProperty("estimatedQuantityKg").GetDecimal(),
                CreatedAt = Time(row)
            });
        foreach (var row in conversations)
        {
            var conversationId = Id(row);
            var messages = Rows(row, "messages");
            var participants = row.GetProperty("participantEmails").EnumerateArray()
                .Select(p => p.GetString() ?? throw new InvalidOperationException("Invalid demo participant.")).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (participants.Count < 2 || messages.Any(m => !participants.Contains(Text(m, "senderEmail"))))
                throw new InvalidOperationException("Invalid demo conversation membership.");
            db.Conversations.Add(new Conversation {
                Id = conversationId, Title = Text(row, "title"),
                PostId = row.TryGetProperty("postId", out var postId) && postId.ValueKind != JsonValueKind.Null ? postId.GetGuid() : null,
                CreatedAt = messages.Min(m => Time(m))
            });
            foreach (var email in participants)
                db.Participants.Add(new Participant { ConversationId = conversationId, UserId = byEmail[email] });
            foreach (var message in messages)
                db.Messages.Add(new Message {
                    Id = Id(message), ConversationId = conversationId, SenderId = byEmail[Text(message, "senderEmail")],
                    Text = Text(message, "text"), ClientMessageId = Text(message, "clientMessageId"), CreatedAt = Time(message)
                });
        }
        foreach (var row in history)
            db.InteractionHistories.Add(new InteractionHistory {
                Id = Id(row), UserId = byEmail[Text(row, "userEmail")], Kind = Text(row, "kind"),
                Title = Text(row, "title"), Body = Text(row, "body"), CreatedAt = Time(row), IsDemo = true
            });
        db.SeedRuns.Add(new SeedRun { Id = SeedId });
        await db.SaveChangesAsync();
        await transaction.CommitAsync();
    }

    private static JsonElement[] Rows(JsonElement row, string name) => row.GetProperty(name).EnumerateArray().ToArray();
    private static string Text(JsonElement row, string name) => row.GetProperty(name).GetString()
        ?? throw new InvalidOperationException($"Missing demo fixture field: {name}.");
    private static Guid Id(JsonElement row) => row.GetProperty("id").GetGuid();
    private static DateTimeOffset Time(JsonElement row) => row.GetProperty("createdAt").GetDateTimeOffset();
}
