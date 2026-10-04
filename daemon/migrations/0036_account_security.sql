CREATE TABLE `audit_events` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`at` integer NOT NULL,
	`action` text NOT NULL,
	`ip` text,
	`user_agent` text,
	`detail` text
);
--> statement-breakpoint
CREATE INDEX `audit_events_at` ON `audit_events` (`at`);--> statement-breakpoint
CREATE TABLE `recovery_codes` (
	`hash` text PRIMARY KEY NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
ALTER TABLE `owner` ADD `totp_secret` text;--> statement-breakpoint
ALTER TABLE `owner` ADD `totp_pending` text;--> statement-breakpoint
ALTER TABLE `owner` ADD `totp_last_step` integer;