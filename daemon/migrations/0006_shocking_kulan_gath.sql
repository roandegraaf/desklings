CREATE TABLE `schedules` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`agent_id` integer NOT NULL,
	`cron` text NOT NULL,
	`prompt` text NOT NULL,
	`paused` integer DEFAULT false NOT NULL,
	`next_run_at` integer NOT NULL,
	`last_run_at` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE no action
);
