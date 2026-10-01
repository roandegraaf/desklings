import type { ToolDef } from './provider.ts';

/**
 * Who holds a desktop's mouse and keyboard. Xvnc knows nothing about owners, so the daemon is
 * the only thing that can hold one.
 *
 * The hold lives in this process rather than in a row, the way the loop cap does. A hold is a
 * human sitting in front of the screen, and a daemon that dies takes every VNC socket with it,
 * so a persisted flag would outlive the person behind it and boot would only have to clear it
 * again. What survives a restart is the agent's side of it: the refusal in its transcript, the
 * `control` event in its history and the state it landed in.
 *
 * ponytail: a hold with a closed browser behind it stays held until the owner returns it or the
 * daemon restarts. Tie it to the live proxy socket if a forgotten tab ever becomes a problem.
 */
export type Control = {
  hold(display: number): void;
  release(display: number): void;
  held(display: number): boolean;
};

export const CONTROL_REFUSAL =
  'the owner has taken control of this desktop: the mouse and keyboard are theirs until they ' +
  'give them back. Stop and wait for the owner rather than trying again.';

/** What the loop and the event log match on, so the wording above can change freely. */
export const CONTROL_HELD = 'control held';

export function createControl(): Control {
  const holders = new Set<number>();
  return {
    hold(display) {
      holders.add(display);
    },
    release(display) {
      holders.delete(display);
    },
    held(display) {
      return holders.has(display);
    },
  };
}

export const MAX_HANDS_REASON_CHARS = 400;

export function askForHandsToolDef(): ToolDef {
  return {
    name: 'ask_for_hands',
    description:
      'Ask the owner to take your screen and do something only a person should or can do there: ' +
      'a login, a CAPTCHA, a choice you may not make. Say exactly what they should do. Calling ' +
      'this ends your turn; you hear from them when they give the screen back.',
    parameters: {
      type: 'object',
      properties: {
        reason: {
          type: 'string',
          maxLength: MAX_HANDS_REASON_CHARS,
          description: 'what the owner should do on the screen, and why you cannot',
        },
      },
      required: ['reason'],
    },
  };
}

export function parseHandsReason(args: Record<string, unknown>): string | { error: string } {
  const reason = typeof args['reason'] === 'string' ? args['reason'].trim() : '';
  if (reason === '') return { error: 'reason is required' };
  if (reason.length > MAX_HANDS_REASON_CHARS) return { error: `reason is longer than ${MAX_HANDS_REASON_CHARS} characters` };
  return reason;
}

export const HANDS_BACK = 'The owner gave the screen back.';
