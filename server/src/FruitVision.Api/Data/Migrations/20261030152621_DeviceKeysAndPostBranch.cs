using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class DeviceKeysAndPostBranch : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "BranchId",
                table: "Posts",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "BiometricDeviceId",
                table: "AuthSessions",
                type: "uuid",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "BiometricDevices",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    DeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    Label = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: false),
                    PublicKey = table.Column<string>(type: "character varying(2048)", maxLength: 2048, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    LastUsedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    RevokedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_BiometricDevices", x => x.Id);
                    table.ForeignKey(
                        name: "FK_BiometricDevices_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "BiometricChallenges",
                columns: table => new
                {
                    Hash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    CredentialId = table.Column<Guid>(type: "uuid", nullable: false),
                    CredentialPublicKeyHash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    SecurityStamp = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                    Payload = table.Column<string>(type: "character varying(2048)", maxLength: 2048, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ConsumedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_BiometricChallenges", x => x.Hash);
                    table.ForeignKey(
                        name: "FK_BiometricChallenges_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_BiometricChallenges_BiometricDevices_CredentialId",
                        column: x => x.CredentialId,
                        principalTable: "BiometricDevices",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_Posts_BranchId",
                table: "Posts",
                column: "BranchId");

            migrationBuilder.CreateIndex(
                name: "IX_AuthSessions_BiometricDeviceId",
                table: "AuthSessions",
                column: "BiometricDeviceId");

            migrationBuilder.CreateIndex(
                name: "IX_BiometricChallenges_CredentialId_ConsumedAt",
                table: "BiometricChallenges",
                columns: new[] { "CredentialId", "ConsumedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_BiometricChallenges_ExpiresAt",
                table: "BiometricChallenges",
                column: "ExpiresAt");

            migrationBuilder.CreateIndex(
                name: "IX_BiometricChallenges_UserId",
                table: "BiometricChallenges",
                column: "UserId");

            migrationBuilder.CreateIndex(
                name: "IX_BiometricDevices_UserId_DeviceId",
                table: "BiometricDevices",
                columns: new[] { "UserId", "DeviceId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_BiometricDevices_UserId_RevokedAt",
                table: "BiometricDevices",
                columns: new[] { "UserId", "RevokedAt" });

            migrationBuilder.AddForeignKey(
                name: "FK_AuthSessions_BiometricDevices_BiometricDeviceId",
                table: "AuthSessions",
                column: "BiometricDeviceId",
                principalTable: "BiometricDevices",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "FK_Posts_SellerBranches_BranchId",
                table: "Posts",
                column: "BranchId",
                principalTable: "SellerBranches",
                principalColumn: "Id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_AuthSessions_BiometricDevices_BiometricDeviceId",
                table: "AuthSessions");

            migrationBuilder.DropForeignKey(
                name: "FK_Posts_SellerBranches_BranchId",
                table: "Posts");

            migrationBuilder.DropTable(
                name: "BiometricChallenges");

            migrationBuilder.DropTable(
                name: "BiometricDevices");

            migrationBuilder.DropIndex(
                name: "IX_Posts_BranchId",
                table: "Posts");

            migrationBuilder.DropIndex(
                name: "IX_AuthSessions_BiometricDeviceId",
                table: "AuthSessions");

            migrationBuilder.DropColumn(
                name: "BranchId",
                table: "Posts");

            migrationBuilder.DropColumn(
                name: "BiometricDeviceId",
                table: "AuthSessions");
        }
    }
}
