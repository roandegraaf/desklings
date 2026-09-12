import { asc, eq } from 'drizzle-orm';
import type { Agent, Approval, ApprovalKind } from '@schermes/shared';
import { AGENT_NAME, findAgent, findAgentById, isWorker } from './agents.ts';
import { participantAgents } from './conversations.ts';
import { approvals } from './schema.ts';
import type { Db } from './db.ts';
import type { ToolDef } from './provider.ts';

const MAX_REASON_CHARS = 512;

/** How many requests may stand at once. An agent that keeps asking would otherwise fill the
 * owner's screen with the same question, and nothing else stops it. */
export const MAX_PENDING_APPROVALS = 20;

export type ApprovalRequest = { kind: ApprovalKind; target: string; reason: string };

function toApproval(db: Db, row: typeof approvals.$inferSelect, agent: string): Approval {
  const kind = row.kind as ApprovalKind;
  return {
    id: row.id,
    agent,
    conversationId: row.conversationId,
    kind,
    target: row.target,
    participants:
      kind === 'conversation'
        ? participantAgents(db, Number(row.target)).map((member) => member.name)
        : [],
    reason: row.reason,
    createdAt: row.createdAt,
  };
}

export function listApprovals(db: Db): Approval[] {
  return db
    .select()
    .from(approvals)
    .orderBy(asc(approvals.id))
    .all()
    .flatMap((row) => {
      const asker = findAgentById(db, row.agentId);
      return asker === undefined ? [] : [toApproval(db, row, asker.name)];
    });
}

export function findApproval(db: Db, id: number): Approval | undefined {
  const row = db.select().from(approvals).where(eq(approvals.id, id)).get();
  if (row === undefined) return undefined;
  const asker = findAgentById(db, row.agentId);
  return asker === undefined ? undefined : toApproval(db, row, asker.name);
}

export function insertApproval(
  db: Db,
  agent: Agent,
  conversationId: number,
  request: ApprovalRequest,
): Approval {
  const row = db
    .insert(approvals)
    .values({
      agentId: agent.id,
      conversationId,
      kind: request.kind,
      target: request.target,
      reason: request.reason,
      createdAt: Date.now(),
    })
    .returning()
    .get();
  return toApproval(db, row, agent.name);
}

export function dropApproval(db: Db, id: number): void {
  db.delete(approvals).where(eq(approvals.id, id)).run();
}

export function pendingCount(db: Db): number {
  return db.select().from(approvals).all().length;
}

/** What a standing request is about, in the words the owner and the agent both read. */
export function describeApproval(approval: Approval): string {
  if (approval.kind === 'agent') {
    return approval.target === approval.agent
      ? `delete itself (${approval.agent})`
      : `delete the agent ${approval.target}`;
  }
  const others = approval.participants.filter((name) => name !== approval.agent);
  return others.length === 0
    ? 'delete the thread it asked in'
    : `delete its thread with ${others.join(', ')}`;
}

/**
 * What the model asked for, or why it cannot be done. The conversation half carries no target
 * from the model at all: an agent never sees a conversation id, so the thread it is in is the
 * only one it can name, and the caller fills that in.
 */
export function parseDeletionRequest(
  db: Db,
  asking: Agent,
  args: Record<string, unknown>,
): { kind: ApprovalKind; target: string; reason: string } | { error: string } {
  const reason = args['reason'];
  if (typeof reason !== 'string' || reason.trim() === '') {
    return { error: 'reason must say why, in a sentence the owner can act on' };
  }
  if (reason.length > MAX_REASON_CHARS) {
    return { error: `reason must be at most ${MAX_REASON_CHARS} characters` };
  }

  const what = args['what'];
  if (what === 'conversation') return { kind: 'conversation', target: '', reason };
  if (what !== 'agent') return { error: "what must be 'agent' or 'conversation'" };

  const target = args['agent'];
  if (typeof target !== 'string' || !AGENT_NAME.test(target)) {
    return { error: `agent must be an agent name matching ${AGENT_NAME.source}` };
  }
  const found = findAgent(db, target);
  if (found === undefined || isWorker(found)) {
    return { error: `no agent named ${target}` };
  }
  return { kind: 'agent', target, reason };
}

export function requestDeletionToolDef(): ToolDef {
  return {
    name: 'request_deletion',
    description:
      'Ask the owner to delete an agent (yours or another), or the thread you are in. Nothing ' +
      'is deleted by this call: the owner is shown the request and answers it, and the answer ' +
      'arrives here as a message later. Ask only when you were told to, or when you are sure ' +
      'the thing is finished with — a deleted agent takes its threads, routines and history ' +
      'with it, and this cannot be undone.',
    parameters: {
      type: 'object',
      properties: {
        what: {
          type: 'string',
          enum: ['agent', 'conversation'],
          description: "'agent' deletes an agent; 'conversation' deletes the thread you are in",
        },
        agent: {
          type: 'string',
          pattern: AGENT_NAME.source,
          description: 'the agent to delete, your own name to delete yourself; only for what=agent',
        },
        reason: { type: 'string', maxLength: MAX_REASON_CHARS },
      },
      required: ['what', 'reason'],
      additionalProperties: false,
    },
  };
}
