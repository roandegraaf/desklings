CREATE TABLE `feedback` (
	`message_id` integer PRIMARY KEY NOT NULL,
	`rating` text NOT NULL,
	`reason` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade
);
