ALTER TABLE `agents` ADD `answered_through` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `messages` ADD `kind` text;--> statement-breakpoint
CREATE TEMP TABLE `shared_threads` AS SELECT `conversation_id` AS `id` FROM `conversation_participants` GROUP BY `conversation_id` HAVING COUNT(*) > 1;
--> statement-breakpoint
DELETE FROM `approvals` WHERE `conversation_id` IN (SELECT `id` FROM `shared_threads`) OR (`kind` = 'conversation' AND CAST(`target` AS INTEGER) IN (SELECT `id` FROM `shared_threads`));
--> statement-breakpoint
DELETE FROM `forms` WHERE `conversation_id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DELETE FROM `summaries` WHERE `conversation_id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DELETE FROM `messages` WHERE `conversation_id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DELETE FROM `read_marks` WHERE `thread` IN (SELECT 'conversation:' || `id` FROM `shared_threads`);
--> statement-breakpoint
UPDATE `agents` SET `parent_conversation_id` = NULL WHERE `parent_conversation_id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DELETE FROM `conversation_participants` WHERE `conversation_id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DELETE FROM `conversations` WHERE `id` IN (SELECT `id` FROM `shared_threads`);
--> statement-breakpoint
DROP TABLE `shared_threads`;
