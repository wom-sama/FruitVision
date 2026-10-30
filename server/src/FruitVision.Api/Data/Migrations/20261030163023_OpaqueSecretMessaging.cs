using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class OpaqueSecretMessaging : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "SecretConversations",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    DirectConversationId = table.Column<Guid>(type: "uuid", nullable: false),
                    FirstUserId = table.Column<Guid>(type: "uuid", nullable: false),
                    SecondUserId = table.Column<Guid>(type: "uuid", nullable: false),
                    NextSequence = table.Column<long>(type: "bigint", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    LastActivityAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecretConversations", x => x.Id);
                    table.CheckConstraint("CK_SecretConversation_Pair", "\"FirstUserId\" <> \"SecondUserId\"");
                    table.CheckConstraint("CK_SecretConversation_Sequence", "\"NextSequence\" >= 0");
                    table.ForeignKey(
                        name: "FK_SecretConversations_AspNetUsers_FirstUserId",
                        column: x => x.FirstUserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretConversations_AspNetUsers_SecondUserId",
                        column: x => x.SecondUserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretConversations_Conversations_DirectConversationId",
                        column: x => x.DirectConversationId,
                        principalTable: "Conversations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SecretDevices",
                columns: table => new
                {
                    DeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    Version = table.Column<int>(type: "integer", nullable: false),
                    Label = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: false),
                    EncryptionPublicKey = table.Column<string>(type: "character varying(44)", maxLength: 44, nullable: false),
                    SigningPublicKey = table.Column<string>(type: "character varying(44)", maxLength: 44, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    RevokedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecretDevices", x => x.DeviceId);
                    table.CheckConstraint("CK_SecretDevice_Version", "\"Version\" >= 1");
                    table.ForeignKey(
                        name: "FK_SecretDevices_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SecretAttachments",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    ConversationId = table.Column<Guid>(type: "uuid", nullable: false),
                    UploaderUserId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    RecipientDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderKeyVersion = table.Column<int>(type: "integer", nullable: false),
                    RecipientKeyVersion = table.Column<int>(type: "integer", nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    Sha256 = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecretAttachments", x => x.Id);
                    table.CheckConstraint("CK_SecretAttachment_Size", "\"SizeBytes\" > 0 AND \"SizeBytes\" <= 5308416");
                    table.ForeignKey(
                        name: "FK_SecretAttachments_AspNetUsers_UploaderUserId",
                        column: x => x.UploaderUserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretAttachments_SecretConversations_ConversationId",
                        column: x => x.ConversationId,
                        principalTable: "SecretConversations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretAttachments_SecretDevices_RecipientDeviceId",
                        column: x => x.RecipientDeviceId,
                        principalTable: "SecretDevices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretAttachments_SecretDevices_SenderDeviceId",
                        column: x => x.SenderDeviceId,
                        principalTable: "SecretDevices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SecretMessages",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    ConversationId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderUserId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderKeyVersion = table.Column<int>(type: "integer", nullable: false),
                    ClientMessageId = table.Column<Guid>(type: "uuid", nullable: false),
                    Sequence = table.Column<long>(type: "bigint", nullable: false),
                    RequestHash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecretMessages", x => x.Id);
                    table.CheckConstraint("CK_SecretMessage_Sequence", "\"Sequence\" >= 1");
                    table.ForeignKey(
                        name: "FK_SecretMessages_AspNetUsers_SenderUserId",
                        column: x => x.SenderUserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretMessages_SecretConversations_ConversationId",
                        column: x => x.ConversationId,
                        principalTable: "SecretConversations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretMessages_SecretDevices_SenderDeviceId",
                        column: x => x.SenderDeviceId,
                        principalTable: "SecretDevices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "SecretEnvelopes",
                columns: table => new
                {
                    MessageId = table.Column<Guid>(type: "uuid", nullable: false),
                    RecipientDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    RecipientUserId = table.Column<Guid>(type: "uuid", nullable: false),
                    RecipientKeyVersion = table.Column<int>(type: "integer", nullable: false),
                    CiphertextBase64 = table.Column<string>(type: "character varying(21848)", maxLength: 21848, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecretEnvelopes", x => new { x.MessageId, x.RecipientDeviceId });
                    table.ForeignKey(
                        name: "FK_SecretEnvelopes_AspNetUsers_RecipientUserId",
                        column: x => x.RecipientUserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretEnvelopes_SecretDevices_RecipientDeviceId",
                        column: x => x.RecipientDeviceId,
                        principalTable: "SecretDevices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_SecretEnvelopes_SecretMessages_MessageId",
                        column: x => x.MessageId,
                        principalTable: "SecretMessages",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_SecretAttachments_ConversationId_CreatedAt",
                table: "SecretAttachments",
                columns: new[] { "ConversationId", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_SecretAttachments_RecipientDeviceId",
                table: "SecretAttachments",
                column: "RecipientDeviceId");

            migrationBuilder.CreateIndex(
                name: "IX_SecretAttachments_SenderDeviceId",
                table: "SecretAttachments",
                column: "SenderDeviceId");

            migrationBuilder.CreateIndex(
                name: "IX_SecretAttachments_UploaderUserId",
                table: "SecretAttachments",
                column: "UploaderUserId");

            migrationBuilder.CreateIndex(
                name: "IX_SecretConversations_DirectConversationId",
                table: "SecretConversations",
                column: "DirectConversationId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_SecretConversations_FirstUserId_LastActivityAt_Id",
                table: "SecretConversations",
                columns: new[] { "FirstUserId", "LastActivityAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_SecretConversations_SecondUserId_LastActivityAt_Id",
                table: "SecretConversations",
                columns: new[] { "SecondUserId", "LastActivityAt", "Id" });

            migrationBuilder.CreateIndex(
                name: "IX_SecretDevices_UserId",
                table: "SecretDevices",
                column: "UserId",
                unique: true,
                filter: "\"RevokedAt\" IS NULL");

            migrationBuilder.CreateIndex(
                name: "IX_SecretDevices_UserId_Version",
                table: "SecretDevices",
                columns: new[] { "UserId", "Version" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_SecretEnvelopes_RecipientDeviceId",
                table: "SecretEnvelopes",
                column: "RecipientDeviceId");

            migrationBuilder.CreateIndex(
                name: "IX_SecretEnvelopes_RecipientUserId_RecipientDeviceId_MessageId",
                table: "SecretEnvelopes",
                columns: new[] { "RecipientUserId", "RecipientDeviceId", "MessageId" });

            migrationBuilder.CreateIndex(
                name: "IX_SecretMessages_ConversationId_SenderUserId_ClientMessageId",
                table: "SecretMessages",
                columns: new[] { "ConversationId", "SenderUserId", "ClientMessageId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_SecretMessages_ConversationId_Sequence",
                table: "SecretMessages",
                columns: new[] { "ConversationId", "Sequence" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_SecretMessages_SenderDeviceId",
                table: "SecretMessages",
                column: "SenderDeviceId");

            migrationBuilder.CreateIndex(
                name: "IX_SecretMessages_SenderUserId",
                table: "SecretMessages",
                column: "SenderUserId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "SecretAttachments");

            migrationBuilder.DropTable(
                name: "SecretEnvelopes");

            migrationBuilder.DropTable(
                name: "SecretMessages");

            migrationBuilder.DropTable(
                name: "SecretConversations");

            migrationBuilder.DropTable(
                name: "SecretDevices");
        }
    }
}
