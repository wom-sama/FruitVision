using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class ConversationReadState
{
    public Guid ConversationId { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset? LastNormalCreatedAt { get; set; }
    public Guid? LastNormalMessageId { get; set; }
    public long LastSecretSequence { get; set; }
}

public static class InboxModels
{
    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<ConversationReadState>(entity =>
        {
            entity.ToTable("ConversationReadStates", table =>
            {
                table.HasCheckConstraint("CK_Inbox_NormalCursor", "(\"LastNormalCreatedAt\" IS NULL) = (\"LastNormalMessageId\" IS NULL)");
                table.HasCheckConstraint("CK_Inbox_SecretCursor", "\"LastSecretSequence\" >= 0");
            });
            entity.HasKey(state => new { state.ConversationId, state.UserId });
            entity.HasIndex(state => state.UserId);
            entity.HasOne<Participant>().WithMany().HasForeignKey(state => new { state.ConversationId, state.UserId }).OnDelete(DeleteBehavior.Cascade);
        });
    }
}
