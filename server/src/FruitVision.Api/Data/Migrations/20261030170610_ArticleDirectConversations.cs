using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class ArticleDirectConversations : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "ArticleId",
                table: "Conversations",
                type: "uuid",
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_ArticleId_InitiatorId",
                table: "Conversations",
                columns: new[] { "ArticleId", "InitiatorId" },
                unique: true);

            migrationBuilder.AddForeignKey(
                name: "FK_Conversations_CommunityArticles_ArticleId",
                table: "Conversations",
                column: "ArticleId",
                principalTable: "CommunityArticles",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_Conversations_CommunityArticles_ArticleId",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_ArticleId_InitiatorId",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "ArticleId",
                table: "Conversations");
        }
    }
}
