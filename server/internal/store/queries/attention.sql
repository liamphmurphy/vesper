-- name: ListInbox :many
-- Every human gate in one list. agent_id, run_id and artifact_id let the
-- Inbox act on an item (reply, retry, cancel, review) without another lookup.
WITH items AS (
 SELECT ('planning:'||pl.id)::text AS id,'planning'::text AS kind,pl.goal AS title,
 CASE WHEN pl.state='review' THEN 'Draft tickets are ready for your review' ELSE coalesce(r.outcome,'Planning run needs attention') END::text AS summary,
 ('/plans?id='||pl.id)::text AS href,p.key AS project,''::text AS ticket_key,greatest(pl.updated_at,r.updated_at)::timestamptz AS created_at,
 (pl.state IN ('accepted','dismissed')) AS resolved, r.agent_id::uuid AS agent_id, r.id AS run_id, NULL::uuid AS artifact_id
 FROM planning_sessions pl LEFT JOIN runs r ON r.id=pl.run_id JOIN projects p ON p.id=pl.project_id
 WHERE pl.workspace_id=sqlc.arg(workspace_id) AND (pl.state<>'planning' OR r.state IN ('failed','cancelled','blocked'))
 UNION ALL
 SELECT ('approval:'||a.id)::text AS id, 'approval'::text AS kind, t.title, a.action_summary AS summary,
 ('/tickets/'||t.key)::text AS href, p.key AS project, t.key AS ticket_key, a.created_at,
 a.state <> 'pending' AS resolved, a.agent_id, a.run_id, NULL
 FROM approval_requests a JOIN tickets t ON t.id=a.ticket_id JOIN projects p ON p.id=t.project_id
 WHERE a.workspace_id=sqlc.arg(workspace_id)
 UNION ALL
 SELECT 'dispatch:'||t.id,'dispatch',t.title,ag.name||' is waiting for dispatch','/tickets/'||t.key,p.key,t.key,greatest(t.updated_at,(SELECT max(b.updated_at) FROM ticket_dependencies d JOIN tickets b ON b.id=d.blocker_id WHERE d.ticket_id=t.id))::timestamptz,false,
 ag.id,NULL,NULL
 FROM tickets t JOIN projects p ON p.id=t.project_id JOIN agents ag ON ag.id=t.assignee_agent_id
 WHERE t.workspace_id=sqlc.arg(workspace_id) AND NOT p.archived AND t.status NOT IN ('done', 'canceled')
 AND NOT EXISTS(SELECT 1 FROM ticket_dependencies d JOIN tickets b ON b.id=d.blocker_id WHERE d.ticket_id=t.id AND b.status<>'done')
 AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.ticket_id=t.id AND r.state NOT IN ('completed','failed','cancelled'))
 UNION ALL
 SELECT 'review:'||t.id,'review',t.title,'Ready for your review','/tickets/'||t.key,p.key,t.key,t.updated_at,false,t.assignee_agent_id,NULL,NULL
 FROM tickets t JOIN projects p ON p.id=t.project_id
 WHERE t.workspace_id=sqlc.arg(workspace_id) AND NOT p.archived AND t.status='in_review' AND t.reviewer_user_id=sqlc.arg(user_id)
 UNION ALL
 SELECT 'blocked:'||r.id,'blocked',t.title,coalesce(r.outcome,'Run needs a person'),'/runs/'||r.id,p.key,t.key,r.updated_at,false,r.agent_id,r.id,NULL
 FROM runs r JOIN tickets t ON t.id=r.ticket_id JOIN projects p ON p.id=t.project_id
 -- Ticket runs only: a delegated child's result goes to its parent, and Retry refuses children.
 WHERE r.workspace_id=sqlc.arg(workspace_id) AND t.status NOT IN ('done', 'canceled') AND r.state IN ('blocked','failed') AND r.parent_run_id IS NULL AND r.ticket_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM runs newer WHERE newer.ticket_id=r.ticket_id AND newer.parent_run_id IS NULL AND newer.started_at>r.started_at)
 UNION ALL
 -- await_human: the summary is the agent's question.
 SELECT 'question:'||r.id,'question',t.title,
 coalesce((SELECT nullif(trim(e.payload->>'reason'),'') FROM activity_events e WHERE e.ticket_id=t.id AND e.verb='waiting_for_human' AND e.payload->>'run_id'=r.id::text ORDER BY e.created_at DESC LIMIT 1),'The agent is waiting for a reply'),
 '/runs/'||r.id,p.key,t.key,r.updated_at,false,r.agent_id,r.id,NULL
 FROM runs r JOIN tickets t ON t.id=r.ticket_id JOIN projects p ON p.id=t.project_id
 WHERE r.workspace_id=sqlc.arg(workspace_id) AND t.status NOT IN ('done', 'canceled') AND r.state='waiting' AND r.wait_reason='human_reply' AND r.ticket_id IS NOT NULL
 UNION ALL
 -- Stalled: running with no event for 30 minutes. created_at is the last activity.
 SELECT 'stalled:'||r.id,'stalled',t.title,'Running, no activity since the last event','/runs/'||r.id,p.key,t.key,
 coalesce(le.at,r.started_at),false,r.agent_id,r.id,NULL
 FROM runs r JOIN tickets t ON t.id=r.ticket_id JOIN projects p ON p.id=t.project_id
 LEFT JOIN LATERAL (SELECT e.at FROM run_events e WHERE e.run_id=r.id ORDER BY e.seq DESC LIMIT 1) le ON true
 WHERE r.workspace_id=sqlc.arg(workspace_id) AND r.state='running' AND r.ticket_id IS NOT NULL
 AND coalesce(le.at,r.started_at) < now()-interval '30 minutes'
 UNION ALL
 -- Up to 4000 characters: ListInbox reads them for a question, then shortens the summary.
 SELECT 'mention:'||c.id,'mention',t.title,left(c.body_md,4000),'/tickets/'||t.key,p.key,t.key,c.created_at,false,
 CASE WHEN c.author_type='agent' THEN c.author_id END,NULL,NULL
 FROM comments c JOIN tickets t ON t.id=c.ticket_id JOIN projects p ON p.id=t.project_id JOIN users u ON u.id=sqlc.arg(user_id)
 WHERE c.workspace_id=sqlc.arg(workspace_id) AND NOT (c.author_type='user' AND c.author_id=u.id)
 AND strpos(c.body_md, '@') > 0
 AND (lower(c.body_md) ~ ('@'||regexp_replace(lower(split_part(u.email,'@',1)), '([^a-z0-9_])', '\\\1','g')||'\y')
 OR lower(c.body_md) LIKE CASE WHEN u.name = '' THEN 'A' ELSE '%@'||regexp_replace(lower(u.name), '([%_\\])', '\\\1', 'g')||'%' END ESCAPE '\')
 UNION ALL
 -- A pull request merged in the last two weeks: news for the Updates tab, nothing to act on.
 SELECT 'merged:'||e.id,'merged',t.title,'Pull request '||coalesce('#'||(e.payload->>'number')||' ','')||'merged','/tickets/'||t.key,p.key,t.key,e.created_at,false,
 t.assignee_agent_id,NULL,NULL
 FROM activity_events e JOIN tickets t ON t.id=e.ticket_id JOIN projects p ON p.id=t.project_id
 WHERE e.workspace_id=sqlc.arg(workspace_id) AND NOT p.archived AND e.verb='pr_merged' AND e.created_at>now()-interval '14 days'
 UNION ALL
 -- A pull request you authored on GitHub was approved in the last two weeks: news, nothing to act on.
 -- The id carries the approval time, so a later approval of the same PR is a new item.
 SELECT 'pr_approved:'||g.id||':'||(extract(epoch FROM g.approved_at)*1000)::bigint,'pr_approved',g.title,
 'Pull request '||g.repository||'#'||g.number||' approved'||CASE WHEN g.approver<>'' THEN ' by '||g.approver ELSE '' END,
 g.url,'','',g.approved_at,false,NULL,NULL,NULL
 FROM github_pr_approvals g
 WHERE g.workspace_id=sqlc.arg(workspace_id) AND g.approved_at>now()-interval '14 days'
 UNION ALL
 SELECT 'suggestion:'||v.id,'suggestion',ar.title,v.note,'/wiki/'||ar.path,coalesce(p.key,''),'',v.created_at,v.state<>'suggested',
 CASE WHEN v.created_by_type='agent' THEN v.created_by_id END,NULL,ar.id
 FROM artifact_versions v JOIN artifacts ar ON ar.id=v.artifact_id LEFT JOIN projects p ON p.id=ar.project_id
 WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.arg(user_id)::uuid) AND ar.workspace_id=sqlc.arg(workspace_id) AND v.state IN ('suggested','published','rejected') AND v.based_on_version_id IS NOT NULL
 UNION ALL
 SELECT 'mockup:'||v.id,'mockup',ar.title,
 CASE v.review_state WHEN 'pending' THEN 'Mockup '||v.label||' is waiting for your approval'
 WHEN 'approved' THEN 'Mockup '||v.label||' approved' ELSE 'Changes requested on mockup '||v.label END,
 '/artifacts/'||ar.id||'/review',coalesce(p.key,''),
 coalesce((SELECT t.key FROM ticket_artifacts ta JOIN tickets t ON t.id=ta.ticket_id WHERE ta.artifact_id=ar.id ORDER BY ta.created_at,t.key LIMIT 1),''),
 v.created_at,(v.review_state<>'pending' OR v.id<>ar.current_version_id),
 CASE WHEN v.created_by_type='agent' THEN v.created_by_id END,NULL,ar.id
 FROM artifact_versions v JOIN artifacts ar ON ar.id=v.artifact_id LEFT JOIN projects p ON p.id=ar.project_id
 WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.arg(user_id)::uuid) AND ar.workspace_id=sqlc.arg(workspace_id) AND ar.type='mockup' AND v.review_state IS NOT NULL
 UNION ALL
 -- Workflow gates are private to the person who started the run.
 -- A scheduled task's result, and a connector tool waiting for a yes or no; both private.
 SELECT 'scheduled:'||r.id,'scheduled',st.name,CASE WHEN r.state='failed' THEN 'Failed: '||r.error ELSE left(r.summary,240) END,
 CASE WHEN r.workflow_run_id IS NOT NULL THEN '/workflows/runs/'||r.workflow_run_id ELSE '/chat/'||r.chat_id END,coalesce(p.key,''),'',r.finished_at,false,NULL,NULL,NULL
 FROM scheduled_task_runs r JOIN scheduled_tasks st ON st.id=r.task_id LEFT JOIN projects p ON p.id=st.project_id
 WHERE st.workspace_id=sqlc.arg(workspace_id) AND st.user_id=sqlc.arg(user_id) AND r.state IN ('done','failed') AND r.finished_at IS NOT NULL
 UNION ALL
 SELECT 'connector_approval:'||a.id,'connector_approval',cn.name,'Wants to use '||a.tool,'/chat/'||a.chat_id,'','',a.created_at,a.state<>'pending',NULL,NULL,NULL
 FROM connector_approvals a JOIN connectors cn ON cn.id=a.connector_id
 WHERE a.workspace_id=sqlc.arg(workspace_id) AND a.user_id=sqlc.arg(user_id) AND a.state='pending'
 UNION ALL
 -- A request with an API secret waiting for a yes or no, and a secret about to stop working; both private.
 SELECT 'secret_approval:'||a.id,'secret_approval',us.name,'Wants to send '||a.method||' to '||coalesce(substring(a.url FROM '^[a-z]+://([^/?#]+)'),a.url),'/chat/'||a.chat_id,'','',a.created_at,a.state<>'pending',NULL,NULL,NULL
 FROM user_secret_approvals a JOIN user_secrets us ON us.id=a.secret_id
 WHERE a.workspace_id=sqlc.arg(workspace_id) AND a.user_id=sqlc.arg(user_id) AND a.state='pending'
 UNION ALL
 SELECT 'secret_expiring:'||us.id||':'||extract(epoch FROM us.expires_at)::bigint,'secret_expiring',us.name,
 CASE WHEN us.expires_at<=now() THEN 'Expired. Replace it to keep using it.' ELSE 'Expires within a day. Replace it to keep using it.' END,
 '/settings?section=secrets&tab=api&secret='||us.id,'','',us.expires_at-interval '1 day',false,NULL,NULL,NULL
 FROM user_secrets us
 WHERE us.workspace_id=sqlc.arg(workspace_id) AND us.user_id=sqlc.arg(user_id) AND us.expires_at<now()+interval '1 day'
 UNION ALL
 SELECT 'workflow_gate:'||s.id,'workflow_gate',wr.name,'A workflow step is waiting for your approval','/workflows/runs/'||wr.id,coalesce(p.key,''),'',s.created_at,s.state<>'waiting',NULL,NULL,NULL
 FROM workflow_steps s JOIN workflow_runs wr ON wr.id=s.run_id LEFT JOIN projects p ON p.id=wr.project_id
 WHERE wr.workspace_id=sqlc.arg(workspace_id) AND wr.user_id=sqlc.arg(user_id) AND (s.state='waiting' OR s.decision<>'')
)
SELECT items.id, items.kind, items.title, items.summary, items.href, items.project, items.ticket_key, items.created_at, items.resolved,
 items.run_id, items.artifact_id, ag.id AS agent_id, coalesce(ag.handle,'')::text AS agent_handle, coalesce(ag.name,'')::text AS agent_name, coalesce(ag.color_index,0)::int AS agent_color_index,
 (rd.read_at IS NOT NULL AND rd.read_at>=items.created_at)::boolean AS read,
 (count(*) FILTER (WHERE NOT items.resolved AND NOT coalesce(rd.read_at>=items.created_at,false)) OVER ())::int AS unread_count
FROM items LEFT JOIN inbox_reads rd ON rd.user_id=sqlc.arg(user_id) AND rd.item_id=items.id
LEFT JOIN agents ag ON ag.id=items.agent_id
WHERE (sqlc.narg(project)::text IS NULL OR items.project=sqlc.narg(project))
-- Open items to act on first, then mentions (which may ask), then news: plenty of unread
-- merged PRs or scheduled results must never push a pending approval past the limit.
ORDER BY items.resolved, (rd.read_at IS NOT NULL AND rd.read_at>=items.created_at),
 CASE WHEN items.kind IN ('scheduled','merged','pr_approved') THEN 2 WHEN items.kind='mention' THEN 1 ELSE 0 END,
 items.created_at DESC,items.id LIMIT 500;

-- name: ReadInboxItem :exec
INSERT INTO inbox_reads (user_id,item_id) VALUES ($1,$2)
ON CONFLICT (user_id,item_id) DO UPDATE SET read_at=clock_timestamp();

-- name: SearchAttentionTargets :many
-- Best matches first, at most per_kind of each kind so many chats or agents
-- can't crowd epics out; total is how many of that kind matched before the
-- cut. only_kind narrows to one kind. Partial words and typos match through
-- trigrams. detail is the hit's context line (a chat's persona, a canvas's
-- chat) and at when it last changed. Personas, memories, Library items,
-- workflows, spaces, courses, scheduled tasks and canvases are private; of
-- those only spaces belong to a project.
WITH needle AS (SELECT lower(replace(sqlc.arg(q)::text,'@','')) AS q)
SELECT kind,id,title,href,status,detail,at,score::float8 AS score,total::int AS total FROM (
SELECT *, row_number() OVER (PARTITION BY kind ORDER BY score DESC,id DESC) AS n, count(*) OVER (PARTITION BY kind) AS total FROM (
SELECT c.*, greatest(word_similarity(needle.q,lower(c.haystack)),similarity(needle.q,lower(c.haystack))) AS score
FROM needle CROSS JOIN LATERAL (
 SELECT 'epic'::text AS kind,e.id,e.name AS title,('/epics?epic='||e.id)::text AS href,''::text AS status,p.key::text AS detail,e.updated_at::timestamptz AS at,e.name AS haystack
 FROM epics e JOIN projects p ON p.id=e.project_id
 WHERE e.workspace_id=sqlc.arg(workspace_id)
 AND (sqlc.narg(project)::text IS NULL OR p.key=sqlc.narg(project))
 UNION ALL
 SELECT 'agent',a.id,a.name,'/agents/'||a.handle,'','@'||a.handle,a.updated_at,a.name||' '||a.handle
 FROM agents a WHERE a.workspace_id=sqlc.arg(workspace_id) AND a.archived_at IS NULL
 AND (sqlc.narg(project)::text IS NULL OR EXISTS (
 SELECT 1 FROM tickets t JOIN projects p ON p.id=t.project_id WHERE t.assignee_agent_id=a.id AND p.key=sqlc.narg(project)))
 UNION ALL
 -- Chats are private: only the asking user's, unarchived, matched by title.
 SELECT 'chat',c.id,c.title,'/chat/'||c.id,'',coalesce(pe.name,''),coalesce(c.last_message_at,c.updated_at),c.title
 FROM chat_sessions c LEFT JOIN projects p ON p.id=c.project_id LEFT JOIN personas pe ON pe.id=c.persona_id
 WHERE c.workspace_id=sqlc.arg(workspace_id) AND c.created_by=sqlc.arg(user_id) AND NOT c.archived AND NOT c.hidden
 AND NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id=c.space_id AND sp.app IS NOT NULL)
 AND (sqlc.narg(project)::text IS NULL OR p.key=sqlc.narg(project))
 UNION ALL
 -- Ticket runs only: chat and workflow runs have their own pages.
 SELECT 'run',r.id,t.key||' · '||a.name,'/runs/'||r.id,r.state,t.title,r.updated_at,t.key||' '||t.title||' '||a.name
 FROM runs r JOIN tickets t ON t.id=r.ticket_id JOIN agents a ON a.id=r.agent_id JOIN projects p ON p.id=t.project_id
 WHERE r.workspace_id=sqlc.arg(workspace_id)
 AND (sqlc.narg(project)::text IS NULL OR p.key=sqlc.narg(project))
 UNION ALL
 SELECT 'workflow',w.id,w.name,'/workflows/'||w.id,'','',w.updated_at,w.name
 FROM workflows w WHERE w.workspace_id=sqlc.arg(workspace_id) AND w.user_id=sqlc.arg(user_id)
 UNION ALL
 SELECT 'persona',pe.id,pe.name,'/settings?section=personas&persona='||pe.id,'','',pe.updated_at,pe.name
 FROM personas pe WHERE pe.workspace_id=sqlc.arg(workspace_id) AND pe.user_id=sqlc.arg(user_id)
 UNION ALL
 SELECT 'memory',m.id,m.title,'/settings?section=memory&id='||m.id,'',m.summary,m.updated_at,m.title||' '||m.summary
 FROM memories m WHERE m.workspace_id=sqlc.arg(workspace_id) AND m.user_id=sqlc.arg(user_id) AND m.superseded_by IS NULL
 UNION ALL
 -- The Library's tab for each kind (library-screen.tsx KINDS), opened on the item.
 SELECT 'library',l.id,l.title,'/library?tab='||CASE l.kind WHEN 'audio' THEN 'audio' ELSE l.kind||'s' END||'&item='||l.id,'',l.kind,l.created_at,l.title
 FROM library_items l WHERE l.workspace_id=sqlc.arg(workspace_id) AND l.user_id=sqlc.arg(user_id)
 UNION ALL
 -- A space that tracks work is found by its project's key too.
 SELECT 'space',sp.id,sp.name,'/spaces/'||sp.id,'',coalesce(p.key,''),sp.updated_at,sp.name||' '||coalesce(p.key,'')
 FROM chat_spaces sp LEFT JOIN projects p ON p.space_id=sp.id
 WHERE sp.workspace_id=sqlc.arg(workspace_id) AND sp.user_id=sqlc.arg(user_id) AND sp.app IS NULL
 AND (sqlc.narg(project)::text IS NULL OR p.key=sqlc.narg(project))
 UNION ALL
 SELECT 'course',lc.id,lc.topic,'/learn/'||lc.id,lc.state,lc.goal,coalesce(lc.ready_at,lc.created_at),lc.topic
 FROM learning_courses lc WHERE lc.workspace_id=sqlc.arg(workspace_id) AND lc.user_id=sqlc.arg(user_id)
 UNION ALL
 SELECT 'scheduled',st.id,st.name,'/scheduled','',st.frequency,st.updated_at,st.name
 FROM scheduled_tasks st WHERE st.workspace_id=sqlc.arg(workspace_id) AND st.user_id=sqlc.arg(user_id)
 UNION ALL
 -- Text and SVG canvases live in their chat; decks and designs are pages already.
 SELECT 'canvas',cv.id,cv.title,'/chat/'||cv.session_id||'?canvas='||cv.id||'&canvas_view=full','',coalesce(nullif(c.title,''),'Untitled chat'),cv.updated_at,cv.title
 FROM chat_canvases cv JOIN chat_sessions c ON c.id=cv.session_id
 WHERE c.workspace_id=sqlc.arg(workspace_id) AND c.created_by=sqlc.arg(user_id) AND NOT c.archived AND NOT c.hidden AND cv.kind IN ('text','svg')
) c
WHERE (sqlc.narg(only_kind)::text IS NULL OR c.kind=sqlc.narg(only_kind))
AND (lower(c.haystack) LIKE '%'||needle.q||'%' OR word_similarity(needle.q,lower(c.haystack))>=0.3)
) matches
) results WHERE n<=sqlc.arg(per_kind)::int ORDER BY score DESC,kind,title,id LIMIT sqlc.arg(lim);
