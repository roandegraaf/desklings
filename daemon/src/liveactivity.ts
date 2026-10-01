import { and, desc, eq, isNull } from 'drizzle-orm';
import type { Agent, LiveActivityAttributes, LiveActivityState } from '@schermes/shared';
import { findAgent } from './agents.ts';
import { existingConversation } from './conversations.ts';
import type { Db } from './db.ts';
import { helperGoal, listGoals } from './goals.ts';
import { log } from './log.ts';
import { listNeedsYou } from './needs.ts';
import { sendEach } from './push.ts';
import type { PushSend, PushTarget } from './push.ts';
import { liveActivityTokens, messages } from './schema.ts';
import type { PushConfig } from './settings.ts';

/** The Swift struct's name; APNs hands it to ActivityKit, which starts nothing for another. */
export const ACTIVITY_ATTRIBUTES_TYPE = 'AgentActivityAttributes';
/** At most one plain update per agent in this window; the last change in it is sent at its end. */
export const ACTIVITY_THROTTLE_MS = 5_000;
/** How long a finished turn stays on the lock screen. */
export const ACTIVITY_DISMISS_S = 15 * 60;
const MAX_TITLE_CHARS = 80;

export type ActivityPush =
  | { event: 'start'; attributes: LiveActivityAttributes; state: LiveActivityState }
  | { event: 'update'; state: LiveActivityState }
  | { event: 'end'; state: LiveActivityState; dismissAt: number };

/** The APNs body; `timestamp` and `dismissAt` are epoch seconds. */
export function activityPayload(push: ActivityPush, timestamp: number): Record<string, unknown> {
  const aps: Record<string, unknown> = { timestamp, event: push.event, 'content-state': push.state };
  if (push.event === 'start') {
    aps['attributes-type'] = ACTIVITY_ATTRIBUTES_TYPE;
    aps['attributes'] = push.attributes;
    aps['input-push-token'] = 1;
    aps['alert'] = { title: push.attributes.label, body: push.state.title || 'Started working.' };
  }
  if (push.event === 'end') aps['dismissal-date'] = push.dismissAt;
  return { aps };
}

export function activityAttributes(agent: Agent): LiveActivityAttributes {
  return { agent: agent.name, label: agent.label ?? agent.name, ...(agent.look === undefined ? {} : { look: agent.look }) };
}

function ownerLine(db: Db, agent: Agent): string {
  const conversation = existingConversation(db, [agent.id]);
  if (conversation === undefined) return '';
  const row = db
    .select({ content: messages.content })
    .from(messages)
    .where(and(eq(messages.conversationId, conversation), eq(messages.role, 'user'), isNull(messages.sender)))
    .orderBy(desc(messages.id))
    .get();
  const line = row?.content.split('\n').find((part) => part.trim() !== '')?.trim() ?? '';
  return line.length > MAX_TITLE_CHARS ? `${line.slice(0, MAX_TITLE_CHARS - 1)}…` : line;
}

export function activityState(db: Db, agent: Agent): LiveActivityState {
  const goal =
    listGoals(db).filter((candidate) => candidate.state === 'open' && candidate.lead === agent.name).at(-1) ??
    helperGoal(db, agent);
  const steps = goal?.steps ?? [];
  return {
    title: goal?.title ?? ownerLine(db, agent),
    stepsDone: steps.filter((step) => step.state === 'done').length,
    stepsTotal: steps.length,
    needsYou: listNeedsYou(db).filter((item) => item.agent === agent.name).length,
    state: agent.state,
  };
}

export function saveActivityToken(db: Db, token: string, kind: 'start' | 'update', agent?: string): void {
  db.insert(liveActivityTokens)
    .values({ token, kind, agent: agent ?? null, createdAt: Date.now() })
    .onConflictDoUpdate({ target: liveActivityTokens.token, set: { kind, agent: agent ?? null } })
    .run();
}

function tokens(db: Db, kind: 'start' | 'update', agent?: string): PushTarget[] {
  const where =
    agent === undefined
      ? eq(liveActivityTokens.kind, kind)
      : and(eq(liveActivityTokens.kind, kind), eq(liveActivityTokens.agent, agent));
  return db
    .select()
    .from(liveActivityTokens)
    .where(where)
    .all()
    .map((row) => ({
      token: row.token,
      label: `live activity ${row.kind}`,
      drop: () => db.delete(liveActivityTokens).where(eq(liveActivityTokens.token, row.token)).run(),
    }));
}

export type LiveActivityDeps = {
  db: Db;
  config: () => PushConfig | undefined;
  send?: PushSend | undefined;
  /** The owner is at a screen that already shows the turn, so no phone activity is started. */
  quiet?: () => boolean;
  throttleMs?: number;
  now?: () => number;
};

type Tracked = {
  running: boolean;
  startSent: boolean;
  lastUpdate: number;
  stamp: number;
  timer?: NodeJS.Timeout | undefined;
  chain: Promise<void>;
};

export type LiveActivities = {
  /** A permanent agent's turn began. */
  started: (agent: Agent) => void;
  /** Its goal's steps or its Needs you items changed mid-turn. */
  changed: (agent: Agent) => void;
  ended: (agent: Agent) => void;
  registered: (token: string, kind: 'start' | 'update', agent?: string) => void;
  /** Resolves once every queued push has gone out; tests wait on it. */
  settled: () => Promise<void>;
};

/**
 * Starts, updates and ends one Live Activity per permanent agent's turn over APNs. A start goes
 * to every phone's push-to-start token; the phone answers with the new activity's own token,
 * and updates and the end go to that. Each agent's pushes are sent in order, so an end never
 * overtakes its start.
 */
export function createLiveActivities(deps: LiveActivityDeps): LiveActivities {
  const throttleMs = deps.throttleMs ?? ACTIVITY_THROTTLE_MS;
  const now = deps.now ?? Date.now;
  const tracked = new Map<string, Tracked>();

  function entry(name: string): Tracked {
    let found = tracked.get(name);
    if (found === undefined) {
      found = { running: false, startSent: false, lastUpdate: 0, stamp: 0, chain: Promise.resolve() };
      tracked.set(name, found);
    }
    return found;
  }

  function queue(name: string, targets: PushTarget[], push: ActivityPush, after?: () => void): void {
    const config = deps.config();
    if (config === undefined || targets.length === 0) return;
    const item = entry(name);
    item.stamp = Math.max(Math.floor(now() / 1000), item.stamp + 1);
    const payload = JSON.stringify(activityPayload(push, item.stamp));
    const urgent = push.event !== 'update' || push.state.needsYou > 0;
    item.chain = item.chain
      .then(() =>
        sendEach(
          { db: deps.db, config, ...(deps.send === undefined ? {} : { send: deps.send }) },
          targets,
          (target, authorization) => ({
            ':method': 'POST',
            ':path': `/3/device/${target.token}`,
            authorization,
            'apns-topic': `${config.bundleId}.push-type.liveactivity`,
            'apns-push-type': 'liveactivity',
            'apns-priority': urgent ? '10' : '5',
            'content-type': 'application/json',
          }),
          payload,
        ),
      )
      .then(() => after?.())
      .catch((error: unknown) => log.error('live activity push failed', { agent: name, error }));
  }

  function current(agent: Agent): Agent {
    return findAgent(deps.db, agent.name) ?? agent;
  }

  function update(name: string): void {
    const item = entry(name);
    item.timer = undefined;
    const agent = findAgent(deps.db, name);
    if (agent === undefined || !item.running) return;
    item.lastUpdate = now();
    queue(name, tokens(deps.db, 'update', name), { event: 'update', state: activityState(deps.db, agent) });
  }

  function end(agent: Agent, targets: PushTarget[]): void {
    queue(
      agent.name,
      targets,
      { event: 'end', state: activityState(deps.db, agent), dismissAt: Math.floor(now() / 1000) + ACTIVITY_DISMISS_S },
      () => {
        for (const target of targets) target.drop();
      },
    );
  }

  const guarded =
    <A extends unknown[]>(what: string, body: (...args: A) => void) =>
    (...args: A): void => {
      try {
        body(...args);
      } catch (error) {
        log.error('live activity failed', { what, error });
      }
    };

  return {
    started: guarded('start', (agent: Agent) => {
      if (agent.parentId !== undefined) return;
      const item = entry(agent.name);
      item.running = true;
      if (tokens(deps.db, 'update', agent.name).length > 0) return update(agent.name);
      if (item.startSent || deps.quiet?.() === true) return;
      const fresh = current(agent);
      const starts = tokens(deps.db, 'start');
      if (starts.length === 0 || deps.config() === undefined) return;
      item.startSent = true;
      queue(agent.name, starts, { event: 'start', attributes: activityAttributes(fresh), state: activityState(deps.db, fresh) });
    }),
    changed: guarded('change', (agent: Agent) => {
      const item = tracked.get(agent.name);
      if (item === undefined || !item.running || item.timer !== undefined) return;
      const wait = item.lastUpdate + throttleMs - now();
      if (wait <= 0) return update(agent.name);
      item.timer = setTimeout(() => guarded('change', update)(agent.name), wait);
      item.timer.unref();
    }),
    ended: guarded('end', (agent: Agent) => {
      const item = tracked.get(agent.name);
      if (item === undefined) return;
      item.running = false;
      item.startSent = false;
      clearTimeout(item.timer);
      item.timer = undefined;
      end(current(agent), tokens(deps.db, 'update', agent.name));
    }),
    registered: guarded('register', (token: string, kind: 'start' | 'update', name?: string) => {
      saveActivityToken(deps.db, token, kind, name);
      if (kind !== 'update' || name === undefined) return;
      const agent = findAgent(deps.db, name);
      if (agent === undefined) return;
      const target = tokens(deps.db, 'update', name).filter((candidate) => candidate.token === token);
      // The turn it was started for may be over before the phone told us where to send the end.
      if (tracked.get(name)?.running === true) queue(name, target, { event: 'update', state: activityState(deps.db, agent) });
      else end(agent, target);
    }),
    settled: async () => {
      await Promise.all([...tracked.values()].map((item) => item.chain));
    },
  };
}
