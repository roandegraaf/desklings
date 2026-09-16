CREATE INDEX `events_agent_id_idx` ON `events` (`agent_id`);--> statement-breakpoint
CREATE INDEX `messages_conversation_id_idx` ON `messages` (`conversation_id`);--> statement-breakpoint
CREATE INDEX `summaries_conversation_id_sender_idx` ON `summaries` (`conversation_id`,`sender`);