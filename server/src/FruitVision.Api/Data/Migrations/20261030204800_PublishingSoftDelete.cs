using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FruitVision.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class PublishingSoftDelete : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "CK_Branch_Status",
                table: "SellerBranches");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Article_Status",
                table: "CommunityArticles");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Branch_Status",
                table: "SellerBranches",
                sql: "\"Status\" IN ('Pending','Approved','Rejected','NeedsInformation','Deleted')");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Article_Status",
                table: "CommunityArticles",
                sql: "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused','Deleted')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "CK_Branch_Status",
                table: "SellerBranches");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Article_Status",
                table: "CommunityArticles");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Branch_Status",
                table: "SellerBranches",
                sql: "\"Status\" IN ('Pending','Approved','Rejected','NeedsInformation')");

            migrationBuilder.AddCheckConstraint(
                name: "CK_Article_Status",
                table: "CommunityArticles",
                sql: "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused')");
        }
    }
}
