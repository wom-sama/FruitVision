using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class NormalImagesAndProfessionalArticles : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "NormalImageId",
                table: "Messages",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "AudienceLane",
                table: "CommunityArticles",
                type: "character varying(20)",
                maxLength: 20,
                nullable: false,
                defaultValue: "Community");

            migrationBuilder.AddColumn<Guid>(
                name: "BranchId",
                table: "CommunityArticles",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "ImageId",
                table: "CommunityArticles",
                type: "uuid",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "NormalImages",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    OwnerId = table.Column<Guid>(type: "uuid", nullable: false),
                    Purpose = table.Column<string>(type: "character varying(12)", maxLength: 12, nullable: false),
                    ConversationId = table.Column<Guid>(type: "uuid", nullable: true),
                    ContentType = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    Width = table.Column<int>(type: "integer", nullable: false),
                    Height = table.Column<int>(type: "integer", nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    RawSha256 = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    Sha256 = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ConsumedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_NormalImages", x => x.Id);
                    table.CheckConstraint("CK_NormalImage_Format", "\"ContentType\"='image/jpeg' AND \"Width\" BETWEEN 1 AND 2048 AND \"Height\" BETWEEN 1 AND 2048 AND \"SizeBytes\" BETWEEN 4 AND 5242880");
                    table.CheckConstraint("CK_NormalImage_Purpose", "(\"Purpose\"='Article' AND \"ConversationId\" IS NULL) OR (\"Purpose\"='Chat' AND \"ConversationId\" IS NOT NULL)");
                    table.ForeignKey(
                        name: "FK_NormalImages_AspNetUsers_OwnerId",
                        column: x => x.OwnerId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_NormalImages_Conversations_ConversationId",
                        column: x => x.ConversationId,
                        principalTable: "Conversations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_Messages_NormalImageId",
                table: "Messages",
                column: "NormalImageId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_AudienceLane_Status_CreatedAt_Id",
                table: "CommunityArticles",
                columns: new[] { "AudienceLane", "Status", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_BranchId",
                table: "CommunityArticles",
                column: "BranchId");

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_ImageId",
                table: "CommunityArticles",
                column: "ImageId",
                unique: true);

            migrationBuilder.AddCheckConstraint(
                name: "CK_Article_Lane",
                table: "CommunityArticles",
                sql: "(\"AudienceLane\"='Community' AND \"BranchId\" IS NULL) OR (\"AudienceLane\"='Professional' AND \"BranchId\" IS NOT NULL)");

            migrationBuilder.CreateIndex(
                name: "IX_NormalImages_ConversationId",
                table: "NormalImages",
                column: "ConversationId");

            migrationBuilder.CreateIndex(
                name: "IX_NormalImages_OwnerId_CreatedAt",
                table: "NormalImages",
                columns: new[] { "OwnerId", "CreatedAt" });

            migrationBuilder.AddForeignKey(
                name: "FK_CommunityArticles_NormalImages_ImageId",
                table: "CommunityArticles",
                column: "ImageId",
                principalTable: "NormalImages",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_CommunityArticles_SellerBranches_BranchId",
                table: "CommunityArticles",
                column: "BranchId",
                principalTable: "SellerBranches",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_Messages_NormalImages_NormalImageId",
                table: "Messages",
                column: "NormalImageId",
                principalTable: "NormalImages",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_CommunityArticles_NormalImages_ImageId",
                table: "CommunityArticles");

            migrationBuilder.DropForeignKey(
                name: "FK_CommunityArticles_SellerBranches_BranchId",
                table: "CommunityArticles");

            migrationBuilder.DropForeignKey(
                name: "FK_Messages_NormalImages_NormalImageId",
                table: "Messages");

            migrationBuilder.DropTable(
                name: "NormalImages");

            migrationBuilder.DropIndex(
                name: "IX_Messages_NormalImageId",
                table: "Messages");

            migrationBuilder.DropIndex(
                name: "IX_CommunityArticles_AudienceLane_Status_CreatedAt_Id",
                table: "CommunityArticles");

            migrationBuilder.DropIndex(
                name: "IX_CommunityArticles_BranchId",
                table: "CommunityArticles");

            migrationBuilder.DropIndex(
                name: "IX_CommunityArticles_ImageId",
                table: "CommunityArticles");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Article_Lane",
                table: "CommunityArticles");

            migrationBuilder.DropColumn(
                name: "NormalImageId",
                table: "Messages");

            migrationBuilder.DropColumn(
                name: "AudienceLane",
                table: "CommunityArticles");

            migrationBuilder.DropColumn(
                name: "BranchId",
                table: "CommunityArticles");

            migrationBuilder.DropColumn(
                name: "ImageId",
                table: "CommunityArticles");
        }
    }
}
