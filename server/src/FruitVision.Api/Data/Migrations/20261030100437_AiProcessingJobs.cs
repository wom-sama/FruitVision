using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class AiProcessingJobs : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AiJobs",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    ClientRequestId = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    MediaType = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    ContentType = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    InputExtension = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    InputBytes = table.Column<long>(type: "bigint", nullable: false),
                    InputSha256 = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    Status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    Progress = table.Column<int>(type: "integer", nullable: false),
                    FramesProcessed = table.Column<int>(type: "integer", nullable: false),
                    Revision = table.Column<long>(type: "bigint", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    CompletedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    Error = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: true),
                    ResultJson = table.Column<string>(type: "jsonb", nullable: true),
                    PreviewAvailable = table.Column<bool>(type: "boolean", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AiJobs", x => x.Id);
                    table.CheckConstraint("CK_AiJob_MediaType", "\"MediaType\" IN ('image','video')");
                    table.CheckConstraint("CK_AiJob_Progress", "\"Progress\" BETWEEN 0 AND 100 AND \"FramesProcessed\" >= 0");
                    table.CheckConstraint("CK_AiJob_Status", "\"Status\" IN ('Queued','Running','Succeeded','Failed','Cancelled')");
                    table.ForeignKey(
                        name: "FK_AiJobs_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AiJobs_Status_CreatedAt",
                table: "AiJobs",
                columns: new[] { "Status", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_AiJobs_UserId",
                table: "AiJobs",
                column: "UserId",
                unique: true,
                filter: "\"Status\" IN ('Queued','Running')");

            migrationBuilder.CreateIndex(
                name: "IX_AiJobs_UserId_ClientRequestId",
                table: "AiJobs",
                columns: new[] { "UserId", "ClientRequestId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_AiJobs_UserId_CreatedAt",
                table: "AiJobs",
                columns: new[] { "UserId", "CreatedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AiJobs");
        }
    }
}
