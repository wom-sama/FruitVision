using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class AuthRolesAndEvidence : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "AuthMethod",
                table: "AuthSessions",
                type: "character varying(40)",
                maxLength: 40,
                nullable: false,
                defaultValue: "password");

            migrationBuilder.AddColumn<string>(
                name: "CountryCode",
                table: "AspNetUsers",
                type: "character varying(2)",
                maxLength: 2,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ProvinceCode",
                table: "AspNetUsers",
                type: "character varying(128)",
                maxLength: 128,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "EmailOtpChallenges",
                columns: table => new
                {
                    Hash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    SecurityStamp = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                    Recipient = table.Column<string>(type: "character varying(254)", maxLength: 254, nullable: false),
                    Purpose = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    CodeHash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    Attempts = table.Column<int>(type: "integer", nullable: false),
                    SendCount = table.Column<int>(type: "integer", nullable: false),
                    SentAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    Consumed = table.Column<bool>(type: "boolean", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmailOtpChallenges", x => x.Hash);
                    table.ForeignKey(
                        name: "FK_EmailOtpChallenges_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "RoleApplications",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    RequestedRole = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    Status = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    Revision = table.Column<int>(type: "integer", nullable: false),
                    OrganisationName = table.Column<string>(type: "character varying(160)", maxLength: 160, nullable: false),
                    Address = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: false),
                    Region = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: false),
                    CountryCode = table.Column<string>(type: "character varying(2)", maxLength: 2, nullable: false),
                    ProvinceCode = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                    Phone = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    Products = table.Column<string[]>(type: "text[]", nullable: false),
                    CultivatedAreaHa = table.Column<decimal>(type: "numeric(12,3)", precision: 12, scale: 3, nullable: true),
                    TaxCode = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    BusinessRegistrationNumber = table.Column<string>(type: "character varying(80)", maxLength: 80, nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    SubmittedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ReviewedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ReviewedById = table.Column<Guid>(type: "uuid", nullable: true),
                    ReviewReason = table.Column<string>(type: "character varying(1000)", maxLength: 1000, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_RoleApplications", x => x.Id);
                    table.CheckConstraint("CK_RoleApplication_Revision", "\"Revision\" >= 1");
                    table.CheckConstraint("CK_RoleApplication_Role", "\"RequestedRole\" IN ('Producer','Trader')");
                    table.CheckConstraint("CK_RoleApplication_Status", "\"Status\" IN ('Draft','Submitted','NeedsInformation','Approved','Rejected')");
                    table.ForeignKey(
                        name: "FK_RoleApplications_AspNetUsers_ReviewedById",
                        column: x => x.ReviewedById,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_RoleApplications_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "RoleApplicationEvidence",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    ApplicationId = table.Column<Guid>(type: "uuid", nullable: false),
                    Category = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    ContentType = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    Sha256 = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_RoleApplicationEvidence", x => x.Id);
                    table.CheckConstraint("CK_RoleEvidence_Category", "\"Category\" IN ('ProductionEvidence','BusinessEvidence')");
                    table.CheckConstraint("CK_RoleEvidence_Size", "\"SizeBytes\" > 0 AND \"SizeBytes\" <= 5242880");
                    table.ForeignKey(
                        name: "FK_RoleApplicationEvidence_RoleApplications_ApplicationId",
                        column: x => x.ApplicationId,
                        principalTable: "RoleApplications",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_EmailOtpChallenges_UserId_SentAt",
                table: "EmailOtpChallenges",
                columns: new[] { "UserId", "SentAt" });

            migrationBuilder.CreateIndex(
                name: "IX_RoleApplicationEvidence_ApplicationId_CreatedAt_Id",
                table: "RoleApplicationEvidence",
                columns: new[] { "ApplicationId", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_RoleApplications_ReviewedById",
                table: "RoleApplications",
                column: "ReviewedById");

            migrationBuilder.CreateIndex(
                name: "IX_RoleApplications_Status_CreatedAt_Id",
                table: "RoleApplications",
                columns: new[] { "Status", "CreatedAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_RoleApplications_UserId",
                table: "RoleApplications",
                column: "UserId",
                unique: true,
                filter: "\"Status\" IN ('Draft','Submitted','NeedsInformation')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "EmailOtpChallenges");

            migrationBuilder.DropTable(
                name: "RoleApplicationEvidence");

            migrationBuilder.DropTable(
                name: "RoleApplications");

            migrationBuilder.DropColumn(
                name: "AuthMethod",
                table: "AuthSessions");

            migrationBuilder.DropColumn(
                name: "CountryCode",
                table: "AspNetUsers");

            migrationBuilder.DropColumn(
                name: "ProvinceCode",
                table: "AspNetUsers");
        }
    }
}
