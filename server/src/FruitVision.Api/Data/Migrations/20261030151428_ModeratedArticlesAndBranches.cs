using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class ModeratedArticlesAndBranches : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "CommunityArticles",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    AuthorId = table.Column<Guid>(type: "uuid", nullable: false),
                    Title = table.Column<string>(type: "character varying(160)", maxLength: 160, nullable: false),
                    Body = table.Column<string>(type: "character varying(5000)", maxLength: 5000, nullable: false),
                    Status = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    Revision = table.Column<int>(type: "integer", nullable: false),
                    ReviewReason = table.Column<string>(type: "character varying(1000)", maxLength: 1000, nullable: true),
                    ReviewedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ReviewedById = table.Column<Guid>(type: "uuid", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_CommunityArticles", x => x.Id);
                    table.CheckConstraint("CK_Article_Revision", "\"Revision\" >= 1");
                    table.CheckConstraint("CK_Article_Status", "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused')");
                    table.ForeignKey(
                        name: "FK_CommunityArticles_AspNetUsers_AuthorId",
                        column: x => x.AuthorId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_CommunityArticles_AspNetUsers_ReviewedById",
                        column: x => x.ReviewedById,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SellerBranches",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    OwnerId = table.Column<Guid>(type: "uuid", nullable: false),
                    Name = table.Column<string>(type: "character varying(160)", maxLength: 160, nullable: false),
                    CountryCode = table.Column<string>(type: "character varying(2)", maxLength: 2, nullable: false),
                    ProvinceCode = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                    CountryName = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: false),
                    ProvinceName = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: false),
                    Region = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: false),
                    Street = table.Column<string>(type: "character varying(240)", maxLength: 240, nullable: false),
                    Phone = table.Column<string>(type: "character varying(30)", maxLength: 30, nullable: false),
                    Status = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    Revision = table.Column<int>(type: "integer", nullable: false),
                    ReviewReason = table.Column<string>(type: "character varying(1000)", maxLength: 1000, nullable: true),
                    ReviewedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ReviewedById = table.Column<Guid>(type: "uuid", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SellerBranches", x => x.Id);
                    table.CheckConstraint("CK_Branch_Revision", "\"Revision\" >= 1");
                    table.CheckConstraint("CK_Branch_Status", "\"Status\" IN ('Pending','Approved','Rejected','NeedsInformation')");
                    table.ForeignKey(
                        name: "FK_SellerBranches_AspNetUsers_OwnerId",
                        column: x => x.OwnerId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SellerBranches_AspNetUsers_ReviewedById",
                        column: x => x.ReviewedById,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_AuthorId_CreatedAt_Id",
                table: "CommunityArticles",
                columns: new[] { "AuthorId", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_ReviewedById",
                table: "CommunityArticles",
                column: "ReviewedById");

            migrationBuilder.CreateIndex(
                name: "IX_CommunityArticles_Status_CreatedAt_Id",
                table: "CommunityArticles",
                columns: new[] { "Status", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_SellerBranches_OwnerId_Status_CreatedAt",
                table: "SellerBranches",
                columns: new[] { "OwnerId", "Status", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_SellerBranches_ReviewedById",
                table: "SellerBranches",
                column: "ReviewedById");

            migrationBuilder.CreateIndex(
                name: "IX_SellerBranches_Status_CreatedAt_Id",
                table: "SellerBranches",
                columns: new[] { "Status", "CreatedAt", "Id" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "CommunityArticles");

            migrationBuilder.DropTable(
                name: "SellerBranches");
        }
    }
}
