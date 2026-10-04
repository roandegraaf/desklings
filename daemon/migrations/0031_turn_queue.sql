CREATE TABLE `turn_queue` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`agent_id` integer NOT NULL,
	`conversation_id` integer NOT NULL,
	`kind` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`agent_id`) REFERENCES `agents`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`conversation_id`) REFERENCES `conversations`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `turn_queue_agent_conversation_idx` ON `turn_queue` (`agent_id`,`conversation_id`);--> statement-breakpoint
ALTER TABLE `agents` ADD `read_through` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
UPDATE `agents` SET `read_through` = (SELECT coalesce(max(`id`), 0) FROM `messages`);
