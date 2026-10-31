using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class PersistentInboxReadState : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "ConversationReadStates",
                columns: table => new
                {
                    ConversationId = table.Column<Guid>(type: "uuid", nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    LastNormalCreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    LastNormalMessageId = table.Column<Guid>(type: "uuid", nullable: true),
                    LastSecretSequence = table.Column<long>(type: "bigint", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ConversationReadStates", x => new { x.ConversationId, x.UserId });
                    table.CheckConstraint("CK_Inbox_NormalCursor", "(\"LastNormalCreatedAt\" IS NULL) = (\"LastNormalMessageId\" IS NULL)");
                    table.CheckConstraint("CK_Inbox_SecretCursor", "\"LastSecretSequence\" >= 0");
                    table.ForeignKey(
                        name: "FK_ConversationReadStates_Participants_ConversationId_UserId",
                        columns: x => new { x.ConversationId, x.UserId },
                        principalTable: "Participants",
                        principalColumns: new[] { "ConversationId", "UserId" },
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_ConversationReadStates_UserId",
                table: "ConversationReadStates",
                column: "UserId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ConversationReadStates");
        }
    }
}
