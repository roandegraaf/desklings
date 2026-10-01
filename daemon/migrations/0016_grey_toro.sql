CREATE TABLE `form_vault` (
	`agent_id` integer NOT NULL,
	`origin` text NOT NULL,
	`keys` text NOT NULL,
	`values` text NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`agent_id`, `origin`),
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `forms` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`agent_id` integer NOT NULL,
	`conversation_id` integer NOT NULL,
	`call_id` text NOT NULL,
	`origin` text NOT NULL,
	`reason` text NOT NULL,
	`fields` text NOT NULL,
	`unfillable` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`conversation_id`) REFERENCES `conversations`(`id`) ON UPDATE no action ON DELETE no action
);
