using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class PostModerationAndCommunity : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateOnly>(
                name: "AvailableOn",
                table: "Posts",
                type: "date",
                nullable: true);

            migrationBuilder.AddColumn<decimal>(
                name: "PriceMaxVndPerKg",
                table: "Posts",
                type: "numeric(14,2)",
                precision: 14,
                scale: 2,
                nullable: true);

            migrationBuilder.AddColumn<decimal>(
                name: "PriceMinVndPerKg",
                table: "Posts",
                type: "numeric(14,2)",
                precision: 14,
                scale: 2,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Purpose",
                table: "Posts",
                type: "character varying(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "Supply");

            migrationBuilder.AddColumn<string>(
                name: "Region",
                table: "Posts",
                type: "character varying(120)",
                maxLength: 120,
                nullable: false,
                defaultValue: "");

            migrationBuilder.AddColumn<string>(
                name: "ReviewReason",
                table: "Posts",
                type: "character varying(1000)",
                maxLength: 1000,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ReviewedAt",
                table: "Posts",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "ReviewedById",
                table: "Posts",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "Revision",
                table: "Posts",
                type: "integer",
                nullable: false,
                defaultValue: 1);

migrationBuilder.AddColumn<Guid>(
                name: "InitiatorId",
                table: "Conversations",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "IsOpen",
                table: "Conversations",
                type: "boolean",
                nullable: false,
                defaultValue: true);

            migrationBuilder.AddColumn<string>(
                name: "Kind",
                table: "Conversations",
                type: "character varying(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "Direct");

            migrationBuilder.AddColumn<Guid>(
                name: "OwnerId",
                table: "Conversations",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ProductCode",
                table: "Conversations",
                type: "character varying(40)",
                maxLength: 40,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Region",
                table: "Conversations",
                type: "character varying(120)",
                maxLength: 120,
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_Posts_ReviewedById",
                table: "Posts",
                column: "ReviewedById");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Post_Prices",
                table: "Posts",
                sql: "(\"PriceMinVndPerKg\" IS NULL AND \"PriceMaxVndPerKg\" IS NULL) OR (\"PriceMinVndPerKg\" IS NOT NULL AND \"PriceMaxVndPerKg\" IS NOT NULL AND \"PriceMinVndPerKg\" > 0 AND \"PriceMaxVndPerKg\" >= \"PriceMinVndPerKg\")");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Post_Purpose",
                table: "Posts",
                sql: "\"Purpose\" IN ('Supply','Demand')");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Post_Revision",
                table: "Posts",
                sql: "\"Revision\" >= 1");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Post_Status",
                table: "Posts",
                sql: "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused','Draft','NeedsChanges','Closed')");

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_InitiatorId",
                table: "Conversations",
                column: "InitiatorId");

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_Kind_IsOpen_CreatedAt_Id",
                table: "Conversations",
                columns: new[] { "Kind", "IsOpen", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_OwnerId",
                table: "Conversations",
                column: "OwnerId");

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_PostId_InitiatorId",
                table: "Conversations",
                columns: new[] { "PostId", "InitiatorId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_ProductCode",
                table: "Conversations",
                column: "ProductCode");

            migrationBuilder.CreateIndex(
                name: "IX_Conversations_Region_ProductCode",
                table: "Conversations",
                columns: new[] { "Region", "ProductCode" });

            migrationBuilder.AddCheckConstraint(
                name: "CK_Conversation_Kind",
                table: "Conversations",
                sql: "\"Kind\" IN ('Direct','Group')");

            migrationBuilder.AddForeignKey(
                name: "FK_Conversations_AspNetUsers_InitiatorId",
                table: "Conversations",
                column: "InitiatorId",
                principalTable: "AspNetUsers",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_Conversations_AspNetUsers_OwnerId",
                table: "Conversations",
                column: "OwnerId",
                principalTable: "AspNetUsers",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_Conversations_Products_ProductCode",
                table: "Conversations",
                column: "ProductCode",
                principalTable: "Products",
                principalColumn: "Code",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_Posts_AspNetUsers_ReviewedById",
                table: "Posts",
                column: "ReviewedById",
                principalTable: "AspNetUsers",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_Conversations_AspNetUsers_InitiatorId",
                table: "Conversations");

            migrationBuilder.DropForeignKey(
                name: "FK_Conversations_AspNetUsers_OwnerId",
                table: "Conversations");

            migrationBuilder.DropForeignKey(
                name: "FK_Conversations_Products_ProductCode",
                table: "Conversations");

            migrationBuilder.DropForeignKey(
                name: "FK_Posts_AspNetUsers_ReviewedById",
                table: "Posts");

            migrationBuilder.DropIndex(
                name: "IX_Posts_ReviewedById",
                table: "Posts");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Post_Prices",
                table: "Posts");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Post_Purpose",
                table: "Posts");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Post_Revision",
                table: "Posts");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Post_Status",
                table: "Posts");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_InitiatorId",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_Kind_IsOpen_CreatedAt_Id",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_OwnerId",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_PostId_InitiatorId",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_ProductCode",
                table: "Conversations");

            migrationBuilder.DropIndex(
                name: "IX_Conversations_Region_ProductCode",
                table: "Conversations");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Conversation_Kind",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "AvailableOn",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "PriceMaxVndPerKg",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "PriceMinVndPerKg",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "Purpose",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "Region",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "ReviewReason",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "ReviewedAt",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "ReviewedById",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "Revision",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "InitiatorId",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "IsOpen",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "Kind",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "OwnerId",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "ProductCode",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "Region",
                table: "Conversations");

}
    }
}

