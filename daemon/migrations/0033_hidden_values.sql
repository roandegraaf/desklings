CREATE TABLE `hidden_values` (
	`agent_id` integer PRIMARY KEY NOT NULL,
	`values` text NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE no action
);
