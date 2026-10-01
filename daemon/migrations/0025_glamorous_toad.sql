CREATE TABLE `live_activity_tokens` (
	`token` text PRIMARY KEY NOT NULL,
	`kind` text NOT NULL,
	`agent` text,
	`created_at` integer NOT NULL
);
