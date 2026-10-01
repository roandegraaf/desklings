CREATE TABLE `goal_helpers` (
	`agent_id` integer PRIMARY KEY NOT NULL,
	`goal_id` integer NOT NULL,
	`kind` text NOT NULL,
	`reason` text NOT NULL,
	`kept_at` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`goal_id`) REFERENCES `goals`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `goals` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`lead_id` integer NOT NULL,
	`title` text NOT NULL,
	`state` text DEFAULT 'open' NOT NULL,
	`steps` text DEFAULT '[]' NOT NULL,
	`results` text DEFAULT '[]' NOT NULL,
	`next_from_you` text DEFAULT '[]' NOT NULL,
	`next_at` integer,
	`helpers_made` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`done_at` integer,
	FOREIGN KEY (`lead_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `goals_lead_id_idx` ON `goals` (`lead_id`);