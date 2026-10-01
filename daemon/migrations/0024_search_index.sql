CREATE VIRTUAL TABLE `screenshots_fts` USING fts5(`text`, tokenize='porter unicode61 remove_diacritics 2');
--> statement-breakpoint
CREATE VIRTUAL TABLE `messages_fts` USING fts5(`content`, content='messages', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2');
--> statement-breakpoint
CREATE TRIGGER `messages_fts_insert` AFTER INSERT ON `messages` BEGIN
  INSERT INTO `messages_fts`(rowid, `content`) VALUES (new.`id`, new.`content`);
END;
--> statement-breakpoint
CREATE TRIGGER `messages_fts_delete` AFTER DELETE ON `messages` BEGIN
  INSERT INTO `messages_fts`(`messages_fts`, rowid, `content`) VALUES ('delete', old.`id`, old.`content`);
  DELETE FROM `screenshots_fts` WHERE rowid = old.`id`;
END;
--> statement-breakpoint
CREATE TRIGGER `messages_fts_update` AFTER UPDATE OF `content` ON `messages` BEGIN
  INSERT INTO `messages_fts`(`messages_fts`, rowid, `content`) VALUES ('delete', old.`id`, old.`content`);
  INSERT INTO `messages_fts`(rowid, `content`) VALUES (new.`id`, new.`content`);
END;
--> statement-breakpoint
INSERT INTO `messages_fts`(`messages_fts`) VALUES ('rebuild');
--> statement-breakpoint
CREATE VIRTUAL TABLE `files_fts` USING fts5(`name`, `path`, `agent_id` UNINDEXED, `modified_at` UNINDEXED, tokenize='porter unicode61 remove_diacritics 2');
