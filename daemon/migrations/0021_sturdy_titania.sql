ALTER TABLE `forms` ADD `trigger_id` integer REFERENCES triggers(id);--> statement-breakpoint
ALTER TABLE `triggers` ADD `login` text;