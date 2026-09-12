import type { Agent } from '@schermes/shared';
import { isWorker, listAgents } from './agents.ts';
import type { Db } from './db.ts';
import type { ToolDef } from './provider.ts';

const MAX_BRIEF_CHARS = 4_096;

/**
 * Where a worker works. Derived from its name rather than chosen by the model, so nothing the
 * model writes ever becomes a path, and it sits under the parent's workspace because the worker
 * runs as the parent's own Linux user.
 */
export function workerDir(parentHome: string, name: string): string {
  return `${parentHome}/workspace/workers/${name}`;
}

/** A worker that has neither finished nor failed is still holding a loop. */
export function liveWorkers(db: Db): Agent[] {
  return listAgents(db).filter(
    (agent) => isWorker(agent) && agent.state !== 'completed' && agent.state !== 'failed',
  );
}

export function parseSpawnWorker(
  body: Record<string, unknown>,
): { brief: string } | { error: string } {
  const brief = body['brief'];
  if (typeof brief !== 'string' || brief.trim() === '') {
    return { error: 'brief must be a non-empty string' };
  }
  if (brief.length > MAX_BRIEF_CHARS) {
    return { error: `brief must be at most ${MAX_BRIEF_CHARS} characters` };
  }
  return { brief };
}

/** Built from the constants `parseSpawnWorker` enforces, so the two cannot disagree. */
export function spawnWorkerToolDef(): ToolDef {
  return {
    name: 'spawn_task_worker',
    description:
      'Hand a self-contained piece of work to a task worker: a throwaway agent that runs as ' +
      'your own Linux user in its own directory under your workspace, does the job and reports ' +
      'back. It can only run shell commands, it cannot see your desktop, and it knows nothing ' +
      'but the brief you give it. Your turn keeps going after this; the result arrives later ' +
      'as a message and wakes you.',
    parameters: {
      type: 'object',
      properties: {
        brief: {
          type: 'string',
          maxLength: MAX_BRIEF_CHARS,
          description: 'the whole job, in enough detail that someone with no other context can do it',
        },
      },
      required: ['brief'],
      additionalProperties: false,
    },
  };
}

/**
 * What a worker is told it is. Opens with `You are <name>,` like a permanent agent's prompt,
 * because that line is how the smoke run's scripted endpoint tells transcripts apart, and names
 * itself a task worker, which is how it tells the two kinds apart.
 */
export function workerPrompt(worker: Agent, parentName: string): string {
  return [
    `You are ${worker.name}, a task worker on this machine.`,
    `${parentName} spawned you to do one job and report back to it.`,
    'run_command runs shell commands as its Linux user, starting in your own working directory',
    'under its workspace; web_search finds pages and web_fetch reads one as text. You have no',
    'desktop and no other tools, and nobody else can write to',
    'you. Do the job, then reply in plain text with the result: that reply is everything',
    `${parentName} will ever see of your work, so say what you did and how it went.`,
  ].join(' ');
}
