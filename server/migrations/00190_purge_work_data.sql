-- +goose Up
-- Wipe all Work-mode data (tickets, epics, plans, ticket runs, saved views,
-- and space/chat project bindings) while keeping shared tables (runs for chat
-- and workflows, artifacts, knowledge_links, approval_requests) intact.

DELETE FROM chat_ticket_runs;
DELETE FROM ticket_change_requests;
DELETE FROM design_frame_links;
DELETE FROM ticket_artifacts;
DELETE FROM ticket_dependencies;
DELETE FROM ticket_labels;
DELETE FROM acceptance_criteria;
DELETE FROM comments;
DELETE FROM activity_events;
DELETE FROM plan_steps;
DELETE FROM planning_sessions;
DELETE FROM epic_criteria;
DELETE FROM run_checkpoints WHERE ticket_id IS NOT NULL;
DELETE FROM approval_requests WHERE ticket_id IS NOT NULL;
DELETE FROM knowledge_links WHERE source_ticket_id IS NOT NULL;
DELETE FROM runs WHERE purpose IN ('ticket', 'planning') OR ticket_id IS NOT NULL;
UPDATE artifacts SET epic_id = NULL WHERE epic_id IS NOT NULL;
DELETE FROM tickets;
DELETE FROM epics;
DELETE FROM labels;
DELETE FROM saved_views;
DELETE FROM inbox_reads;
UPDATE chat_spaces SET project_id = NULL WHERE project_id IS NOT NULL;
UPDATE chat_sessions SET project_id = NULL WHERE project_id IS NOT NULL;

-- +goose Down
-- Data purge is intentionally irreversible.
SELECT 1;
