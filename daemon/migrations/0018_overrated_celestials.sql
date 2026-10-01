CREATE TABLE `idle_passes` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`agent_id` integer NOT NULL,
	`started_at` integer NOT NULL,
	`matched` text NOT NULL,
	`outcome` text NOT NULL,
	`tokens` integer DEFAULT 0 NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `idle_passes_agent_id_idx` ON `idle_passes` (`agent_id`);--> statement-breakpoint
ALTER TABLE `agents` ADD `idle` text;