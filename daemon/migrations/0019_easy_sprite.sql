CREATE TABLE `idle_outputs` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`pass_id` integer NOT NULL,
	`kind` text NOT NULL,
	`body` text NOT NULL,
	`created_at` integer NOT NULL,
	`resolved` text,
	FOREIGN KEY (`pass_id`) REFERENCES `idle_passes`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `idle_outputs_pass_id_idx` ON `idle_outputs` (`pass_id`);--> statement-breakpoint
ALTER TABLE `idle_passes` ADD `ended_at` integer;--> statement-breakpoint
ALTER TABLE `idle_passes` ADD `reason` text;