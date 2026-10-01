ALTER TABLE `approvals` ADD `category` text DEFAULT 'delete_files' NOT NULL;--> statement-breakpoint
ALTER TABLE `approvals` ADD `amount` text;--> statement-breakpoint
ALTER TABLE `approvals` ADD `origin` text;