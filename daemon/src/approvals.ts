import { and, asc, eq, isNull } from 'drizzle-orm';
import { APPROVAL_CATEGORIES } from '@schermes/shared';
import type { Agent, Approval, ApprovalCategory, ApprovalKind, ApprovalOutcome } from '@schermes/shared';
import { AGENT_NAME, findAgent, findAgentById, isWorker } from './agents.ts';
import { participantAgents } from './conversations.ts';
import { approvals } from './schema.ts';
import type { Db } from './db.ts';
import type { ToolDef } from './provider.ts';

const MAX_REASON_CHARS = 512;
export const MAX_TARGET_CHARS = 256;
const MAX_AMOUNT_CHARS = 64;

/** How many requests may stand at once. An agent that keeps asking would otherwise fill the
 * owner's screen with the same question, and nothing else stops it. */
export const MAX_PENDING_APPROVALS = 20;

export type ApprovalRequest = {
  kind: ApprovalKind;
  target: string;
  reason: string;
  category?: ApprovalCategory;
  amount?: string;
  origin?: string;
};

/** Read as "asks to …". */
export const APPROVED = 'The owner approved your request to ';
export const GO_AHEAD = '. Go ahead.';

export const CATEGORY_WORDS: Record<ApprovalCategory, string> = {
  browse: 'browse',
  run_commands: 'run a command',
  write_files: 'write files',
  delete_files: 'delete files',
  send_messages: 'send a message',
  spend_money: 'spend money',
  install_software: 'install software',
  share_outside: 'share something outside',
  passwords_security: 'change a password or security setting',
};

function toApproval(db: Db, row: typeof approvals.$inferSelect, agent: string): Approval {
  const kind = row.kind as ApprovalKind;
  return {
    id: row.id,
    agent,
    conversationId: row.conversationId,
    kind,
    category: row.category as ApprovalCategory,
    target: row.target,
    ...(row.amount === null ? {} : { amount: row.amount }),
    ...(row.origin === null ? {} : { origin: row.origin }),
    participants:
      kind === 'conversation'
        ? participantAgents(db, Number(row.target)).map((member) => member.name)
        : [],
    reason: row.reason,
    createdAt: row.createdAt,
    ...(row.callId === null ? {} : { callId: row.callId }),
    ...(row.outcome === null ? {} : { outcome: row.outcome as ApprovalOutcome }),
    ...(row.decidedAt === null ? {} : { decidedAt: row.decidedAt }),
  };
}

function withAsker(db: Db, rows: (typeof approvals.$inferSelect)[]): Approval[] {
  return rows.flatMap((row) => {
    const asker = findAgentById(db, row.agentId);
    return asker === undefined ? [] : [toApproval(db, row, asker.name)];
  });
}

/** The requests still waiting for the owner. */
export function listApprovals(db: Db): Approval[] {
  return withAsker(db, db.select().from(approvals).where(isNull(approvals.decidedAt)).orderBy(asc(approvals.id)).all());
}

/** Every request asked in one thread, answered or not. */
export function threadApprovals(db: Db, conversationId: number): Approval[] {
  return withAsker(
    db,
    db.select().from(approvals).where(eq(approvals.conversationId, conversationId)).orderBy(asc(approvals.id)).all(),
  );
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
  callId?: string,
): Approval {
  const row = db
    .insert(approvals)
    .values({
      agentId: agent.id,
      conversationId,
      kind: request.kind,
      category: request.category ?? 'delete_files',
      target: request.target,
      amount: request.amount ?? null,
      origin: request.origin ?? null,
      reason: request.reason,
      createdAt: Date.now(),
      callId: callId ?? null,
    })
    .returning()
    .get();
  return toApproval(db, row, agent.name);
}

/** Records the owner's answer. False when it was already answered, so a second tap is no second answer. */
export function settleApproval(db: Db, id: number, outcome: ApprovalOutcome, now: number): boolean {
  return (
    db
      .update(approvals)
      .set({ outcome, decidedAt: now })
      .where(and(eq(approvals.id, id), isNull(approvals.decidedAt)))
      .run().changes === 1
  );
}

export function pendingCount(db: Db): number {
  return listApprovals(db).length;
}

/** What a standing request is about, in the words the owner and the agent both read. */
export function describeApproval(approval: Approval): string {
  if (approval.kind === 'action') {
    return (
      CATEGORY_WORDS[approval.category] +
      (approval.target === '' ? '' : `: ${approval.target}`) +
      (approval.amount === undefined ? '' : ` (${approval.amount})`) +
      (approval.origin === undefined ? '' : ` at ${approval.origin}`)
    );
  }
  if (approval.kind === 'agent') {
    return approval.target === approval.agent
      ? `delete itself (${approval.agent})`
      : `delete the agent ${approval.target}`;
  }
  return 'delete the thread it asked in';
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
  const reason = parseReason(args);
  if (typeof reason !== 'string') return reason;

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

function parseReason(args: Record<string, unknown>): string | { error: string } {
  const reason = args['reason'];
  if (typeof reason !== 'string' || reason.trim() === '') {
    return { error: 'reason must say why, in a sentence the owner can act on' };
  }
  if (reason.length > MAX_REASON_CHARS) {
    return { error: `reason must be at most ${MAX_REASON_CHARS} characters` };
  }
  return reason;
}

function optionalLine(
  args: Record<string, unknown>,
  key: string,
  max: number,
): string | undefined | { error: string } {
  const value = args[key];
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || /[\r\n]/.test(value) || value.trim().length > max) {
    return { error: `${key} must be one line of at most ${max} characters` };
  }
  return value.trim() === '' ? undefined : value.trim();
}

export function parseApprovalRequest(args: Record<string, unknown>): ApprovalRequest | { error: string } {
  const category = args['category'];
  if (typeof category !== 'string' || !(APPROVAL_CATEGORIES as readonly string[]).includes(category)) {
    return { error: `category must be one of ${APPROVAL_CATEGORIES.join(', ')}` };
  }
  const reason = parseReason(args);
  if (typeof reason !== 'string') return reason;
  const target = optionalLine(args, 'target', MAX_TARGET_CHARS);
  const amount = optionalLine(args, 'amount', MAX_AMOUNT_CHARS);
  const origin = optionalLine(args, 'origin', MAX_TARGET_CHARS);
  for (const field of [target, amount, origin]) {
    if (typeof field === 'object') return field;
  }
  return {
    kind: 'action',
    category: category as ApprovalCategory,
    target: (target as string | undefined) ?? '',
    reason,
    ...(amount === undefined ? {} : { amount: amount as string }),
    ...(origin === undefined ? {} : { origin: origin as string }),
  };
}

export function requestApprovalToolDef(): ToolDef {
  return {
    name: 'request_approval',
    description:
      'Ask the owner before you do something they may not want done without them: spending ' +
      'money, sending a message on their behalf, installing software, sharing something outside, ' +
      'and the like. Passwords and security settings are the owner\'s alone: ask with category ' +
      'passwords_security so they see it, and they do it themselves. Nothing happens by this call: ' +
      'the owner is shown the request, and the ' +
      'answer arrives here as a message later. Do not do the thing until it says approved. To ' +
      'delete an agent or a thread, use request_deletion instead.',
    parameters: {
      type: 'object',
      properties: {
        category: { type: 'string', enum: [...APPROVAL_CATEGORIES] },
        reason: {
          type: 'string',
          maxLength: MAX_REASON_CHARS,
          description: 'what you want to do and why, in a sentence the owner can act on',
        },
        target: {
          type: 'string',
          maxLength: MAX_TARGET_CHARS,
          description: 'what it acts on: a recipient, a package, a path, a payee',
        },
        amount: {
          type: 'string',
          maxLength: MAX_AMOUNT_CHARS,
          description: 'what it costs, with the currency, e.g. "EUR 42.50"',
        },
        origin: {
          type: 'string',
          maxLength: MAX_TARGET_CHARS,
          description: 'the site or service it happens on, e.g. "shop.example.com"',
        },
      },
      required: ['category', 'reason'],
      additionalProperties: false,
    },
  };
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
