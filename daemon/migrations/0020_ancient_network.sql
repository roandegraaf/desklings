CREATE TABLE `triggers` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`agent_id` integer NOT NULL,
	`kind` text NOT NULL,
	`config` text NOT NULL,
	`reason` text NOT NULL,
	`state` text DEFAULT 'proposed' NOT NULL,
	`token` text,
	`secret` text,
	`max_per_hour` integer NOT NULL,
	`window_started_at` integer,
	`fired_in_window` integer DEFAULT 0 NOT NULL,
	`dropped` integer DEFAULT 0 NOT NULL,
	`cursor` text,
	`checked_at` integer,
	`last_fired_at` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `triggers_token_unique` ON `triggers` (`token`);--> statement-breakpoint
CREATE INDEX `triggers_agent_id_idx` ON `triggers` (`agent_id`);