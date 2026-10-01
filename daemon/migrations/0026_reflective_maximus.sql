CREATE TABLE `providers` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`name` text NOT NULL,
	`base_url` text NOT NULL,
	`api_key` text,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
ALTER TABLE `models` ADD `provider_id` integer REFERENCES providers(id);